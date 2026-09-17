# utils_duckdb ---
# Shared internal helpers for the pure-R/DuckDB backend.
#
# openalexSnapshot deliberately takes no openalexPro dependency: it is the
# offline half of the ecosystem and must not pull in httr2/curl/jqr. The few
# things it needs from there (the id_block formula) are reimplemented here.

# -- connections ------------------------------------------------------------

#' Open a configured in-memory DuckDB connection
#'
#' @param memory_limit DuckDB memory limit, e.g. `"8GB"`. `NULL` for default.
#' @param temp_dir Spill directory. `NULL` for the DuckDB default.
#' @param threads Thread count. `NULL` for the DuckDB default.
#' @param preserve_order Value for `preserve_insertion_order`. Set `FALSE` for
#'   throughput; set `TRUE` whenever the statement's `ORDER BY` must survive
#'   into the written parquet, which is what makes row-group pruning work.
#' @return A DBI connection. The caller is responsible for disconnecting.
#' @noRd
#' Default operator
#'
#' Defined locally: base R only gained `%||%` in 4.4.
#'
#' @keywords internal
#' @noRd
`%||%` <- function(x, y) if (is.null(x)) y else x

.oas_con <- function(memory_limit = NULL,
                     temp_dir = NULL,
                     threads = NULL,
                     preserve_order = FALSE) {
  con <- DBI::dbConnect(duckdb::duckdb(), read_only = FALSE)
  DBI::dbExecute(con, paste0(
    "SET preserve_insertion_order = ", if (isTRUE(preserve_order)) "true" else "false"
  ))
  if (!is.null(memory_limit)) {
    DBI::dbExecute(con, paste0("SET memory_limit = ", .oas_sql_str(memory_limit)))
  }
  if (!is.null(threads)) {
    DBI::dbExecute(con, paste0("SET threads = ", as.integer(threads)))
  }
  if (!is.null(temp_dir)) {
    dir.create(temp_dir, recursive = TRUE, showWarnings = FALSE)
    DBI::dbExecute(con, paste0("SET temp_directory = ", .oas_sql_str(temp_dir)))
  }
  con
}

#' Quote a value as a SQL string literal
#' @noRd
.oas_sql_str <- function(x) {
  paste0("'", gsub("'", "''", as.character(x), fixed = TRUE), "'")
}

#' Render a character vector as a SQL list of quoted paths
#' @noRd
.oas_sql_paths <- function(paths) {
  paste0("[", paste(.oas_sql_str(.oas_fwd(paths)), collapse = ", "), "]")
}

#' Normalise a path to forward slashes (DuckDB wants them on all platforms)
#' @noRd
.oas_fwd <- function(x) gsub("\\", "/", x, fixed = TRUE)

# -- identifiers ------------------------------------------------------------

#' Block number for an OpenAlex ID
#'
#' `floor(numeric_id / 10000)`, byte-identical to `openalexPro::id_block()` and
#' to the Rust index builder. Used for the `id_block` column of the ID and DOI
#' indexes.
#'
#' Note this is *not* the citation index's partition key: at
#' `floor(n / 1e4)` the largest OpenAlex work id yields ~714,000 blocks, which
#' is unusable as a directory partition. See [build_citation_index()], which
#' uses `floor(n / block_size)` with `block_size = 1e7`.
#'
#' @param ids Character vector of OpenAlex IDs, any form.
#' @return Integer vector.
#' @noRd
.oas_id_block <- function(ids) {
  numeric_part <- as.numeric(sub(".*?(\\d+)$", "\\1", ids))
  as.integer(floor(numeric_part / 10000))
}

#' Numeric part of an OpenAlex ID
#' @noRd
.oas_id_numeric <- function(ids) {
  as.numeric(sub(".*?(\\d+)$", "\\1", ids))
}

#' Normalise OpenAlex IDs to long form
#'
#' Accepts short (`W2741809807`) and long
#' (`https://openalex.org/W2741809807`) form; the entity letter is upper-cased.
#'
#' @param ids Character vector.
#' @return Character vector of long-form IDs.
#' @noRd
.oas_normalize_id <- function(ids) {
  ids <- trimws(as.character(ids))
  bare <- sub("^https?://openalex\\.org/", "", ids, ignore.case = TRUE)
  bare <- sub("^([A-Za-z])", "\\U\\1", bare, perl = TRUE)
  paste0("https://openalex.org/", bare)
}

#' Is a string an OpenAlex ID (short or long form)?
#' @noRd
.oas_is_id <- function(x) {
  grepl("^(https?://openalex\\.org/)?[WwAaSsIiCcPpFfTtKkGg][0-9]+$", trimws(x))
}

# -- DOIs -------------------------------------------------------------------

#' Normalise a DOI to the index key form
#'
#' Strips a resolver prefix (`https://doi.org/`, `http://dx.doi.org/`) or a
#' `doi:` scheme, trims, and lower-cases. All of these normalise to the same
#' key:
#'
#' ```
#' 10.1016/j.joi.2017.08.007
#' https://doi.org/10.1016/j.joi.2017.08.007
#' http://dx.doi.org/10.1016/j.joi.2017.08.007
#' doi:10.1016/j.joi.2017.08.007
#' DOI: 10.1016/J.JOI.2017.08.007
#' ```
#'
#' This must stay in exact agreement with the SQL used on the write side by
#' [build_doi_index()]:
#' `lower(regexp_replace(doi, '^https?://(dx\\.)?doi\\.org/', ''))`.
#' `tests/testthat/test-build_doi_index.R` asserts the round trip.
#'
#' Deliberately *not* `openalexPro::extract_doi()`: that is an extractor, not a
#' normaliser. It returns the first DOI-shaped substring of its input, so a
#' malformed input yields a plausible-looking wrong key rather than an error.
#'
#' @param x Character vector.
#' @return Character vector of bare lower-case DOIs.
#' @noRd
.oas_normalize_doi <- function(x) {
  x <- trimws(as.character(x))
  x <- sub("^doi:\\s*", "", x, ignore.case = TRUE)
  x <- sub("^https?://(dx\\.)?doi\\.org/", "", x, ignore.case = TRUE)
  tolower(trimws(x))
}

#' Does a string look like a DOI?
#' @noRd
.oas_is_doi <- function(x) {
  grepl("^10\\.[0-9]{4,9}/", .oas_normalize_doi(x))
}

# -- corpus layout ----------------------------------------------------------

#' Resolve a snapshot path to its parquet root
#'
#' Accepts either a `root_dir` containing a `parquet/` subdirectory, or the
#' parquet directory itself. The `openalex_snapshot` symlink in the ecosystem
#' workspace points at the parquet level, so both must work.
#'
#' When the path does not exist this returns `<path>/parquet` unchanged rather
#' than erroring, preserving the historical `file.path(root_dir, "parquet")`
#' behaviour. Path derivation and existence checking are separate concerns: the
#' corpus read that follows will report a missing directory with better
#' context. Pass `must_exist = TRUE` to check here instead.
#'
#' @param path Character scalar.
#' @param must_exist Error if the path does not resolve to a real directory.
#' @return Path to the parquet root.
#' @noRd
.oas_parquet_root <- function(path, must_exist = FALSE) {
  if (is.null(path)) stop("A snapshot path is required.", call. = FALSE)
  nested <- file.path(path, "parquet")
  if (dir.exists(nested)) return(normalizePath(nested))
  if (dir.exists(path)) return(normalizePath(path))
  if (isTRUE(must_exist)) {
    stop("Snapshot path does not exist: ", path, call. = FALSE)
  }
  nested
}

#' List the parquet files of a corpus directory
#' @noRd
.oas_corpus_files <- function(corpus_dir) {
  f <- list.files(corpus_dir, pattern = "\\.parquet$",
                  recursive = TRUE, full.names = TRUE)
  if (length(f) == 0L) {
    stop("No parquet files found under: ", corpus_dir, call. = FALSE)
  }
  sort(f)
}

#' Group files into batches of at most `batch_bytes`
#'
#' The corpus is extremely skewed - one `updated_date=` partition can hold half
#' the works while hundreds hold megabytes - so batching by directory produces
#' wildly uneven work. Batch by byte budget over the flat file list instead.
#'
#' @param files Character vector of file paths.
#' @param batch_bytes Target maximum bytes per batch.
#' @return A list of character vectors.
#' @noRd
.oas_plan_batches <- function(files, batch_bytes = 8e9) {
  sizes <- file.info(files)$size
  sizes[is.na(sizes)] <- 0
  batches <- list()
  cur <- character(0)
  cur_bytes <- 0
  for (i in seq_along(files)) {
    if (length(cur) > 0L && cur_bytes + sizes[i] > batch_bytes) {
      batches[[length(batches) + 1L]] <- cur
      cur <- character(0)
      cur_bytes <- 0
    }
    cur <- c(cur, files[i])
    cur_bytes <- cur_bytes + sizes[i]
  }
  if (length(cur) > 0L) batches[[length(batches) + 1L]] <- cur
  batches
}

# -- block sizing -----------------------------------------------------------

#' Derive a block width from the actual id range of a corpus
#'
#' A fixed width cannot serve every entity, because id ranges differ by orders
#' of magnitude. Works ids span nearly the whole 0-7.1e9 range, so a width of
#' 1e7 yields 351 useful blocks. Author ids cluster in 5.0-5.1e9, where the
#' same width yields **14** blocks for 113 million rows -- partitions of ~8M
#' rows that prune almost nothing.
#'
#' Sampling the extremes and dividing by a target block count adapts to both.
#' The result is approximate: ids are not uniformly distributed within their
#' range, so the realised block count differs from the target, and empty blocks
#' are simply never created.
#'
#' @param files Corpus parquet files.
#' @param target Desired number of blocks.
#' @return A numeric block width, at least 1e4.
#' @noRd
.oas_derive_block_size <- function(files, target = 300L) {
  probe <- unique(c(utils::head(files, 3L), utils::tail(files, 3L)))
  con <- .oas_con()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  r <- DBI::dbGetQuery(con, paste0(
    "SELECT min(n) AS lo, max(n) AS hi FROM (SELECT TRY_CAST(",
    "regexp_extract(id, '([0-9]+)$', 1) AS UBIGINT) AS n FROM read_parquet(",
    .oas_sql_paths(probe), ", hive_partitioning = false)) WHERE n IS NOT NULL"))
  span <- as.numeric(r$hi[[1L]]) - as.numeric(r$lo[[1L]])
  if (!is.finite(span) || span <= 0) return(1e7)
  max(1e4, signif(span / target, 2))
}

# -- disk space -------------------------------------------------------------

#' Free bytes on the filesystem holding `path`
#'
#' Uses `df`, so it returns `NA` on platforms without it rather than guessing.
#' Callers must treat `NA` as "unknown" and not block on it.
#' @noRd
.oas_free_bytes <- function(path) {
  while (!dir.exists(path) && dirname(path) != path) path <- dirname(path)
  out <- tryCatch(
    suppressWarnings(system2("df", c("-Pk", shQuote(path)), stdout = TRUE, stderr = FALSE)),
    error = function(e) NULL
  )
  if (length(out) < 2L) return(NA_real_)
  f <- suppressWarnings(as.numeric(strsplit(trimws(out[[2L]]), "\\s+")[[1L]][4L]))
  if (is.na(f)) NA_real_ else f * 1024
}

#' Refuse to start a build that cannot fit
#'
#' The default `temp_dir` is on local disk, which is typically far smaller than
#' the volume holding the snapshot. Failing here beats failing with ENOSPC an
#' hour into a build.
#'
#' @param temp_dir Where shards and spill will go.
#' @param need_bytes Estimated peak requirement.
#' @param what Label for the message.
#' @noRd
.oas_check_space <- function(temp_dir, need_bytes, what = "index") {
  free <- .oas_free_bytes(temp_dir)
  if (is.na(free)) return(invisible(NULL))          # unknown: do not block
  gb <- function(x) round(x / 1024^3, 1)
  if (free < need_bytes) {
    stop(sprintf(
      paste0("Not enough space for the %s under %s: %.1f GB free, ",
             "an estimated %.1f GB needed.\n",
             "Pass temp_dir = to a disk with more room. Prefer a fast local ",
             "disk that is NOT the one holding the corpus -- spill competing ",
             "with corpus reads is itself a large slowdown."),
      what, temp_dir, gb(free), gb(need_bytes)), call. = FALSE)
  }
  if (free < need_bytes * 1.5) {
    warning(sprintf("Only %.1f GB free under %s for the %s (estimated need %.1f GB).",
                    gb(free), temp_dir, what, gb(need_bytes)), call. = FALSE)
  }
  invisible(NULL)
}

# -- referenced_works encoding ----------------------------------------------

#' Determine how `referenced_works` is encoded, and how to unnest it
#'
#' The official OpenAlex parquet stores `referenced_works` as a native
#' `VARCHAR[]`; the legacy JSON-converted corpus stores it as a `VARCHAR`
#' holding a JSON array. Both must work.
#'
#' The sniff has to happen in R. A SQL `CASE WHEN typeof(...)` will not bind,
#' because both branches of the expression must yield the same type and the
#' native-list branch is invalid when the column is `VARCHAR`.
#'
#' @param con A DuckDB connection.
#' @param files Character vector of corpus files; the first and last are
#'   sniffed and must agree (a partially refreshed corpus could be mixed).
#' @param alias Table alias to qualify the column with.
#' @return List with `expr` (SQL yielding `VARCHAR[]`) and `enc`.
#' @noRd
#' Make DuckDB's `json` extension available on this connection
#'
#' Called only when the corpus stores `referenced_works` as JSON text, which
#' is the one thing here that needs the extension -- a native-list corpus
#' needs nothing.
#'
#' DuckDB can autoload extensions on demand, but autoinstall is not always
#' enabled and the download needs network access, so on a CI runner the first
#' `json_extract_string()` fails with "Extension Autoloading Error ... not
#' found". An explicit `INSTALL` does work there. Installing an extension that
#' is already present is a cheap no-op, so this is safe to call per
#' connection.
#'
#' @param con A DuckDB connection.
#' @return `TRUE`, invisibly; errors with an actionable message otherwise.
#' @noRd
.oas_ensure_json <- function(con) {
  status <- tryCatch(
    {
      DBI::dbExecute(con, "INSTALL json")
      DBI::dbExecute(con, "LOAD json")
      TRUE
    },
    error = function(e) conditionMessage(e)
  )
  if (!isTRUE(status)) {
    stop(
      "This corpus stores `referenced_works` as JSON text, which needs ",
      "DuckDB's `json` extension. It could not be loaded:\n  ",
      sub("\n.*", "", status), "\n\n",
      "Install it once on this machine, in any R session with network ",
      "access:\n",
      "  con <- DBI::dbConnect(duckdb::duckdb())\n",
      "  DBI::dbExecute(con, \"INSTALL json\")\n\n",
      "A corpus whose `referenced_works` is a native list needs no ",
      "extension at all.",
      call. = FALSE
    )
  }
  invisible(TRUE)
}

.oas_refs_expr <- function(con, files, alias = "w") {
  probe <- unique(c(files[1L], files[length(files)]))
  encs <- vapply(probe, function(f) {
    ty <- DBI::dbGetQuery(con, paste0(
      "SELECT column_type FROM (DESCRIBE SELECT referenced_works FROM read_parquet(",
      .oas_sql_str(.oas_fwd(f)), ") LIMIT 0)"
    ))$column_type[[1L]]
    if (grepl("\\[\\]$", ty)) {
      "native_list"
    } else if (toupper(ty) %in% c("VARCHAR", "JSON")) {
      "json_varchar"
    } else {
      stop("Unsupported referenced_works column type: ", ty, call. = FALSE)
    }
  }, character(1))

  if (length(unique(encs)) > 1L) {
    stop(
      "referenced_works is encoded inconsistently across the corpus (",
      paste(unique(encs), collapse = " and "),
      "). Rebuild or refresh the corpus so one encoding is used throughout.",
      call. = FALSE
    )
  }

  enc <- unname(encs[[1L]])
  expr <- if (enc == "native_list") {
    paste0(alias, ".referenced_works")
  } else {
    .oas_ensure_json(con)
    paste0("json_extract_string(", alias, ".referenced_works, '$[*]')")
  }
  list(expr = expr, enc = enc)
}

# -- index metadata ---------------------------------------------------------

#' Write the one-row metadata sidecar for an index
#'
#' Written *last* by a builder: its presence is what marks the index complete.
#' @noRd
.oas_write_index_meta <- function(path, meta) {
  arrow::write_parquet(as.data.frame(meta), file.path(path, "_index_meta.parquet"))
  invisible(file.path(path, "_index_meta.parquet"))
}

#' Read an index metadata sidecar
#' @noRd
.oas_read_index_meta <- function(path) {
  f <- file.path(path, "_index_meta.parquet")
  if (!file.exists(f)) return(NULL)
  as.data.frame(arrow::read_parquet(f))
}

#' Assert that an index exists and is complete
#'
#' Distinguishes "absent" from "present but incomplete" - the latter means an
#' interrupted build, and the message says so.
#' @noRd
.oas_require_index <- function(path, kind, builder, hint_arg = "root_dir", hint_val = NULL) {
  cls <- c(paste0("openalexSnapshot_missing_", kind, "_index"),
           "openalexSnapshot_missing_index")
  call_hint <- sprintf("%s(%s = \"%s\")", builder, hint_arg,
                       if (is.null(hint_val)) "<snapshot>" else hint_val)

  if (kind %in% c("citation", "id")) {
    if (!dir.exists(path)) {
      rlang::abort(
        c(x = sprintf("No %s index at %s.", kind, path),
          i = sprintf("Build it with %s.", call_hint)),
        class = cls, index_path = path, builder = builder
      )
    }
    if (!file.exists(file.path(path, "_index_meta.parquet"))) {
      rlang::abort(
        c(x = sprintf("The %s index at %s appears incomplete.", kind, path),
          i = "_index_meta.parquet is missing, which means an interrupted build.",
          i = sprintf("Re-run %s with overwrite = TRUE.", builder)),
        class = c("openalexSnapshot_incomplete_index", cls),
        index_path = path, builder = builder
      )
    }
  } else if (!file.exists(path)) {
    rlang::abort(
      c(x = sprintf("No %s index at %s.", kind, path),
        i = sprintf("Build it with %s.", call_hint)),
      class = cls, index_path = path, builder = builder
    )
  }
  invisible(path)
}

# -- backend selection ------------------------------------------------------

#' Resolve the `backend` argument
#'
#' The compiled Rust backend was removed in 0.1.0. The argument is retained so
#' that existing calls passing `backend = "rust"` get an explanatory error
#' rather than an opaque "unused argument", and so `backend = "r"` keeps
#' working unchanged.
#' @noRd
.oas_backend <- function(backend = c("auto", "r", "rust")) {
  backend <- match.arg(backend)
  if (backend == "rust") {
    stop(
      "backend = \"rust\" was removed in openalexSnapshot 0.1.0.\n",
      "The package is now pure R: there is no compiled code and no Rust ",
      "toolchain is required to install it. The R implementation is also the ",
      "better one -- it writes a sorted index, which lets lookup_by_id() prune ",
      "row groups instead of scanning the whole file, and it supports ",
      "`columns` and `add_columns`.\n",
      "Drop the argument, or pass backend = \"r\".",
      call. = FALSE
    )
  }
  "r"
}
