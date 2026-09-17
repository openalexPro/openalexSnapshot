#' Find the works citing, or cited by, given keypapers
#'
#' `get_citing()` returns the works that **cite** the keypapers; `get_cited()`
#' returns the works the keypapers **reference**. Both work entirely offline
#' against a local snapshot.
#'
#' The two are not symmetric in cost. `get_cited()` only needs the keypaper's
#' own `referenced_works` column, so it uses the ID index alone. `get_citing()`
#' asks the opposite question, which the snapshot does not answer directly --
#' `cited_by_api_url` is a URL -- so it needs the inverted index from
#' [build_citation_index()].
#'
#' @param keypaper Character **vector** of one or more keypapers. Forms may be
#'   mixed freely in a single call:
#'   * short OpenAlex ID, `"W3045921891"`
#'   * long OpenAlex ID, `"https://openalex.org/W3045921891"`
#'   * bare DOI, `"10.1016/j.joi.2017.08.007"`
#'   * DOI with resolver, `"https://doi.org/10.7717/peerj.4375"`
#'
#'   All keypapers are resolved and queried in one pass, not in a loop.
#' @param root_dir Root directory containing a `parquet/` subdirectory, or the
#'   parquet directory itself.
#' @param return What to return:
#'   * `"edges"` (default) -- a data frame of `from`/`to` long-form IDs, where
#'     a row `A, B` means **A cites B**. This keeps the mapping between each
#'     keypaper and its neighbours, which a flat ID vector would lose when
#'     `keypaper` has length > 1, and it is directly `rbind`-able into a
#'     snowball edge set.
#'   * `"ids"` -- the unique non-keypaper endpoint, as a character vector.
#'   * `"records"` -- the full records for those IDs, via [lookup_by_id()].
#' @param output Directory to write records to when `return = "records"`. When
#'   `NULL`, records are returned as a data frame.
#' @param columns Column projection passed to [lookup_by_id()] when
#'   `return = "records"`.
#' @param max_results Error if more edges than this are found. A single heavily
#'   cited work can have hundreds of thousands of citing works, and the
#'   follow-on record extraction would then touch essentially every file in the
#'   corpus. Set `Inf` to lift the guard deliberately.
#' @param depth Reserved for multi-hop snowballing; only `1` is implemented.
#' @param citation_index Explicit path to a `*_cite_idx` directory.
#' @param id_index Explicit path to a `*_id_idx` directory.
#' @param doi_index Explicit path to a `*_doi_idx.parquet`.
#' @param data_set Dataset name used to locate indexes under `root_dir`.
#' @param workers Parallel workers for record extraction.
#' @param temp_dir Root for DuckDB's spill files. `NULL` (default) uses a
#'   private directory under [tempdir()]. Never DuckDB's own default, which is
#'   `.tmp` relative to the working directory and is therefore shared by every
#'   concurrent caller.
#' @param memory_limit DuckDB memory limit.
#' @param verbose Print progress.
#'
#' @return A data frame of edges, a character vector of IDs, or records --
#'   see `return`.
#'
#' @seealso [build_citation_index()], [build_doi_index()], [lookup_by_id()]
#' @export
get_citing <- function(keypaper,
                       root_dir = NULL,
                       return = c("edges", "ids", "records"),
                       output = NULL,
                       columns = NULL,
                       max_results = 100000L,
                       depth = 1L,
                       citation_index = NULL,
                       id_index = NULL,
                       doi_index = NULL,
                       data_set = "works",
                       workers = NULL,
                       memory_limit = NULL,
                       temp_dir = NULL,
                       verbose = TRUE) {
  return <- match.arg(return)
  .oas_check_depth(depth)
  kp <- .oas_resolve_keypaper(keypaper, root_dir = root_dir,
                              doi_index = doi_index, data_set = data_set,
                              verbose = verbose)
  if (length(kp) == 0L) return(.oas_empty_result(return))

  if (is.null(citation_index)) {
    citation_index <- file.path(.oas_parquet_root(root_dir),
                                paste0(data_set, "_cite_idx"))
  }
  .oas_require_index(citation_index, "citation", "build_citation_index",
                     hint_val = if (!is.null(root_dir)) root_dir else NULL)

  meta <- .oas_read_index_meta(citation_index)
  .oas_warn_if_stale(meta, verbose = verbose)
  block_size <- as.numeric(meta$block_size[[1L]])

  num    <- .oas_id_numeric(kp)
  blocks <- unique(floor(num / block_size))
  # Build the file list explicitly rather than globbing the index: globbing
  # opens every partition footer and would undo the point-lookup speed the
  # partitioning exists to provide.
  parts  <- file.path(citation_index, sprintf("cited_block=%d", blocks),
                      "part-0.parquet")
  parts  <- parts[file.exists(parts)]
  if (length(parts) == 0L) return(.oas_empty_result(return))

  if (isTRUE(verbose)) {
    message("Reading ", length(parts), " index partition(s) for ",
            length(kp), " keypaper(s) ...")
  }

  # A private spill directory, not DuckDB's `.tmp` relative to the working
  # directory: concurrent callers (a pool of pro_snowball() runs, say) would
  # otherwise share one and corrupt each other's spill files.
  ctmp <- temp_dir %||% file.path(tempdir(), "oas_citing", basename(tempfile("c")))
  con <- .oas_con(memory_limit = memory_limit, temp_dir = ctmp)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  on.exit(unlink(ctmp, recursive = TRUE, force = TRUE), add = TRUE)

  # The index stores long-form IDs, so they come straight out.
  edges <- DBI::dbGetQuery(con, paste0(
    "SELECT citing_id AS \"from\", cited_id AS \"to\" ",
    "FROM read_parquet(", .oas_sql_paths(parts), ", hive_partitioning = false) ",
    "WHERE cited_id IN (", paste(.oas_sql_str(kp), collapse = ", "), ") ",
    "ORDER BY \"to\", \"from\""
  ))

  .oas_finish(edges, which = "from", return = return, max_results = max_results,
              root_dir = root_dir, id_index = id_index, data_set = data_set,
              output = output, columns = columns, workers = workers,
              memory_limit = memory_limit, verbose = verbose)
}

#' @rdname get_citing
#' @export
get_cited <- function(keypaper,
                      root_dir = NULL,
                      return = c("edges", "ids", "records"),
                      output = NULL,
                      columns = NULL,
                      max_results = 100000L,
                      depth = 1L,
                      id_index = NULL,
                      doi_index = NULL,
                      data_set = "works",
                      workers = NULL,
                      memory_limit = NULL,
                      temp_dir = NULL,
                      verbose = TRUE) {
  return <- match.arg(return)
  .oas_check_depth(depth)
  kp <- .oas_resolve_keypaper(keypaper, root_dir = root_dir,
                              doi_index = doi_index, data_set = data_set,
                              verbose = verbose)
  if (length(kp) == 0L) return(.oas_empty_result(return))

  if (is.null(id_index)) {
    id_index <- file.path(.oas_parquet_root(root_dir),
                          paste0(data_set, "_id_idx"))
  }

  # Only two of ~51 columns are needed. This projection is the reason
  # lookup_by_id() grew a `columns` argument.
  recs <- lookup_by_id(ids = kp, index_file = id_index, backend = "r",
                       columns = c("id", "referenced_works"),
                       workers = workers, memory_limit = memory_limit,
                       temp_dir = temp_dir, verbose = verbose)
  if (nrow(recs) == 0L) return(.oas_empty_result(return))

  # A private spill directory, not DuckDB's `.tmp` relative to the working
  # directory: concurrent callers (a pool of pro_snowball() runs, say) would
  # otherwise share one and corrupt each other's spill files.
  ctmp <- temp_dir %||% file.path(tempdir(), "oas_citing", basename(tempfile("c")))
  con <- .oas_con(memory_limit = memory_limit, temp_dir = ctmp)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  on.exit(unlink(ctmp, recursive = TRUE, force = TRUE), add = TRUE)
  duckdb::duckdb_register(con, "recs", recs)

  ty <- DBI::dbGetQuery(con,
    "SELECT column_type FROM (DESCRIBE SELECT referenced_works FROM recs LIMIT 0)"
  )$column_type[[1L]]
  refs <- if (grepl("\\[\\]$", ty)) {
    "w.referenced_works"
  } else {
    .oas_ensure_json(con)
    "json_extract_string(w.referenced_works, '$[*]')"
  }

  edges <- DBI::dbGetQuery(con, paste0(
    "SELECT w.id AS \"from\", r.ref AS \"to\" ",
    "FROM recs AS w, LATERAL UNNEST(", refs, ") AS r(ref) ",
    "WHERE w.referenced_works IS NOT NULL ORDER BY \"from\", \"to\""
  ))

  .oas_finish(edges, which = "to", return = return, max_results = max_results,
              root_dir = root_dir, id_index = id_index, data_set = data_set,
              output = output, columns = columns, workers = workers,
              memory_limit = memory_limit, verbose = verbose)
}

# -- shared internals -------------------------------------------------------

#' @noRd
.oas_check_depth <- function(depth) {
  if (!identical(as.integer(depth), 1L)) {
    stop("Only depth = 1 is implemented. Iterate get_citing()/get_cited() ",
         "for multi-hop snowballing.", call. = FALSE)
  }
}

#' @noRd
.oas_empty_result <- function(return) {
  switch(return,
    edges = data.frame(from = character(0), to = character(0),
                       stringsAsFactors = FALSE),
    ids = character(0),
    records = data.frame()
  )
}

#' Resolve mixed IDs and DOIs to long-form OpenAlex work IDs
#'
#' Classifies each element independently, so a single call may mix short IDs,
#' long IDs, bare DOIs and resolver DOIs.
#' @noRd
.oas_resolve_keypaper <- function(keypaper,
                                  root_dir = NULL,
                                  doi_index = NULL,
                                  data_set = "works",
                                  verbose = TRUE) {
  if (missing(keypaper) || length(keypaper) == 0L) {
    stop("`keypaper` must be provided and non-empty.", call. = FALSE)
  }
  x <- trimws(as.character(keypaper))
  x <- unique(x[!is.na(x) & nzchar(x)])
  if (length(x) == 0L) {
    stop("`keypaper` contains no usable values.", call. = FALSE)
  }

  is_id  <- .oas_is_id(x)
  is_doi <- !is_id & .oas_is_doi(x)
  bad    <- !is_id & !is_doi
  if (any(bad)) {
    stop("Not an OpenAlex ID or a DOI: ",
         paste(utils::head(x[bad], 5L), collapse = ", "),
         if (sum(bad) > 5L) paste0(", and ", sum(bad) - 5L, " more") else "",
         call. = FALSE)
  }

  ids <- character(0)
  if (any(is_id)) {
    norm <- .oas_normalize_id(x[is_id])
    entity <- sub("^https://openalex\\.org/([A-Z]).*$", "\\1", norm)
    if (any(entity != "W")) {
      stop("get_citing()/get_cited() apply to works; got ",
           paste(unique(norm[entity != "W"]), collapse = ", "), call. = FALSE)
    }
    ids <- c(ids, norm)
  }

  if (any(is_doi)) {
    res <- doi_to_id(x[is_doi], root_dir = root_dir, index_file = doi_index,
                     data_set = data_set, verbose = verbose)
    if (anyNA(res$id)) {
      warning(.oas_unresolved_msg(res$doi_input[is.na(res$id)]), call. = FALSE)
    }
    ids <- c(ids, stats::na.omit(res$id))
  }

  unique(ids)
}

#' Warn (never error) when the index looks out of step with the corpus
#'
#' A deliberately frozen snapshot must stay usable, so this is not an error.
#' @noRd
.oas_warn_if_stale <- function(meta, verbose = TRUE) {
  if (is.null(meta) ||
      !isTRUE(getOption("openalexSnapshot.check_index_staleness", TRUE))) {
    return(invisible(NULL))
  }
  corpus <- meta$corpus_dir[[1L]]
  if (!dir.exists(corpus)) return(invisible(NULL))
  files <- list.files(corpus, pattern = "\\.parquet$", recursive = TRUE,
                      full.names = TRUE)
  if (length(files) != meta$n_source_files[[1L]]) {
    warning("The citation index was built from ", meta$n_source_files[[1L]],
            " files but the corpus now has ", length(files),
            ". Results may be incomplete; rebuild with overwrite = TRUE. ",
            "Silence with options(openalexSnapshot.check_index_staleness = FALSE).",
            call. = FALSE)
  }
  invisible(NULL)
}

#' Turn an edge frame into the requested return shape
#' @noRd
.oas_finish <- function(edges, which, return, max_results, root_dir, id_index,
                        data_set, output, columns, workers, memory_limit,
                        verbose) {
  if (nrow(edges) > max_results) {
    stop(nrow(edges), " edges found, above max_results = ", max_results, ". ",
         "Extracting records for this many ids would read most of the corpus. ",
         "Raise max_results deliberately, or use return = \"edges\".",
         call. = FALSE)
  }
  if (return == "edges") return(edges)

  ids <- unique(edges[[which]])
  if (return == "ids") return(ids)

  if (length(ids) == 0L) return(data.frame())
  if (is.null(id_index)) {
    id_index <- file.path(.oas_parquet_root(root_dir),
                          paste0(data_set, "_id_idx"))
  }
  if (isTRUE(verbose)) {
    message("Extracting ", length(ids), " record(s) ...")
  }
  lookup_by_id(ids = ids, index_file = id_index, backend = "r",
               columns = columns, output = output, workers = workers,
               verbose = verbose)
}
