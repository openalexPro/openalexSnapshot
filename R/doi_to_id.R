#' Resolve DOIs to OpenAlex IDs offline
#'
#' Looks DOIs up in the index built by [build_doi_index()]. DOIs may be given
#' with or without a resolver prefix; all of these resolve identically:
#'
#' ```
#' 10.1016/j.joi.2017.08.007
#' https://doi.org/10.1016/j.joi.2017.08.007
#' http://dx.doi.org/10.1016/j.joi.2017.08.007
#' doi:10.1016/j.joi.2017.08.007
#' DOI: 10.1016/J.JOI.2017.08.007
#' ```
#'
#' @param doi Character vector of DOIs.
#' @param root_dir Root directory containing a `parquet/` subdirectory, or the
#'   parquet directory itself.
#' @param index_file Explicit path to a `*_doi_idx.parquet`. Overrides
#'   `root_dir`.
#' @param data_set Dataset name used to locate the index under `root_dir`.
#' @param verbose Print progress.
#'
#' @return A data frame with one row per input, in input order:
#'   \describe{
#'     \item{doi_input}{The string as supplied}
#'     \item{doi}{Its normalised key}
#'     \item{id}{The OpenAlex ID in long form, or `NA` if unresolved}
#'   }
#'   A data frame rather than a bare vector, because the caller needs to know
#'   *which* inputs failed to resolve.
#'
#' @seealso [build_doi_index()], [lookup_by_doi()]
#' @export
doi_to_id <- function(doi,
                      root_dir = NULL,
                      index_file = NULL,
                      data_set = "works",
                      verbose = TRUE) {
  if (missing(doi) || length(doi) == 0L) {
    stop("`doi` must be provided and non-empty.", call. = FALSE)
  }
  if (is.null(index_file)) {
    if (is.null(root_dir)) {
      stop("Provide either `root_dir` or `index_file`.", call. = FALSE)
    }
    index_file <- file.path(.oas_parquet_root(root_dir),
                            paste0(data_set, "_doi_idx.parquet"))
  }
  .oas_require_index(index_file, "doi", "build_doi_index",
                     hint_val = if (!is.null(root_dir)) root_dir else NULL)

  key <- .oas_normalize_doi(doi)
  if (isTRUE(verbose)) message("Resolving ", length(unique(key)), " DOI(s) ...")

  con <- .oas_con()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  hits <- DBI::dbGetQuery(con, paste0(
    "SELECT doi, any_value(id) AS id FROM read_parquet(",
    .oas_sql_str(.oas_fwd(index_file)), ") WHERE doi IN (",
    paste(.oas_sql_str(unique(key)), collapse = ", "), ") GROUP BY doi"
  ))

  out <- data.frame(doi_input = as.character(doi), doi = key,
                    stringsAsFactors = FALSE)
  out$id <- hits$id[match(out$doi, hits$doi)]
  out
}

#' Look up records by DOI
#'
#' Convenience wrapper: [doi_to_id()] followed by [lookup_by_id()].
#'
#' @inheritParams doi_to_id
#' @param id_index Explicit path to a `*_id_idx` directory.
#' @param ... Passed to [lookup_by_id()], e.g. `columns` or `output`.
#'
#' @return Whatever [lookup_by_id()] returns.
#' @seealso [doi_to_id()], [lookup_by_id()]
#' @export
lookup_by_doi <- function(doi,
                          root_dir = NULL,
                          index_file = NULL,
                          id_index = NULL,
                          data_set = "works",
                          verbose = TRUE,
                          ...) {
  res <- doi_to_id(doi, root_dir = root_dir, index_file = index_file,
                   data_set = data_set, verbose = verbose)
  unresolved <- res$doi_input[is.na(res$id)]
  if (length(unresolved)) {
    warning(.oas_unresolved_msg(unresolved), call. = FALSE)
  }
  ids <- stats::na.omit(res$id)
  if (length(ids) == 0L) return(data.frame())

  if (is.null(id_index)) {
    id_index <- file.path(.oas_parquet_root(root_dir),
                          paste0(data_set, "_id_idx"))
  }
  lookup_by_id(ids = ids, index_file = id_index, backend = "r",
               verbose = verbose, ...)
}

#' Format an "unresolved DOIs" warning
#'
#' Lists at most five, then a count. Never silently drops.
#' @noRd
.oas_unresolved_msg <- function(x) {
  n <- length(x)
  shown <- utils::head(x, 5L)
  paste0(
    n, " DOI(s) could not be resolved against the DOI index: ",
    paste(shown, collapse = ", "),
    if (n > 5L) paste0(", and ", n - 5L, " more") else ""
  )
}
