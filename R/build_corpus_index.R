#' Build a Parquet ID-lookup index
#'
#' Builds a `<dataset>_id_idx/` index from the Parquet corpus produced
#' by the snapshot download and conversion pipeline, enabling fast record retrieval by OpenAlex ID
#' using [lookup_by_id()].
#'
#' The function uses a two-stage approach:
#' 1. Index each Parquet file individually (bounded memory, parallel, with
#'    resume support).
#' 2. Combine the per-file shard indexes into a single Parquet index.
#'
#' Paths can be supplied as a single `root_dir` (which iterates over all
#' requested `data_sets`) or as an explicit `corpus_dir` pointing to a single
#' dataset directory.
#'
#' @param root_dir Root directory containing a `parquet/` subdirectory produced
#'   by the snapshot conversion pipeline. If provided, the index for each dataset in
#'   `data_sets` is created at `<root_dir>/parquet/<dataset>_id_idx/`.
#' @param data_sets Character vector of dataset names to index (e.g.
#'   `c("works", "authors")`). `NULL` indexes all datasets found under
#'   `<root_dir>/parquet/`. Ignored when `corpus_dir` is provided.
#' @param workers Number of parallel workers for Stage 1 indexing. Default is
#'   `NULL` (sequential).
#' @param memory_limit DuckDB memory limit (e.g., `"20GB"`). Default is `NULL`.
#' @param temp_dir Directory for Stage-1 shards and DuckDB spill. Defaults to a
#'   subdirectory of [tempdir()], which is on local disk.
#'
#'   The default matters. Spilling beside the index puts those writes on the
#'   same device the corpus is being read from, and on an external USB SSD that
#'   measured **8.18 s/batch versus 0.76 s/batch** -- a 10.8x difference from
#'   this setting alone. Override it only to point at a *different* fast disk,
#'   or if the default lacks room: peak usage is roughly the size of the
#'   finished index plus its transient shards.
#' @param batch_bytes Approximate bytes of source parquet per Stage-1 batch.
#' @param block_size Width of an `id_block`. `NULL` (default) derives one from
#'   the actual id range so the index lands near 300 blocks.
#'
#'   A fixed width does not suit every dataset, because entity id ranges differ
#'   by orders of magnitude. At `1e7`, works gives 351 useful blocks but
#'   authors gives only **14** -- their ids cluster tightly around 5.0-5.1e9,
#'   so 113 million rows would land in 14 partitions of ~8 M rows and prune
#'   almost nothing. Pass a value explicitly to override.
#' @param overwrite If `TRUE`, rebuilds existing indexes. Default is `FALSE`
#'   (skip if the index already exists).
#' @param verbose Print progress messages. Default is `TRUE`.
#' @param corpus_dir Explicit path to a single dataset Parquet directory (e.g.
#'   `"/Volumes/openalex/parquet/works"`). The index is written as a sibling
#'   directory: `<parent>/<basename>_id_idx/`. When this is provided,
#'   `root_dir` and `data_sets` are ignored.
#' @param backend Retained only so that existing calls passing
#'   `backend = "rust"` get an explanatory error. The compiled backend was
#'   removed in 0.1.0; the package is pure R. `"auto"` (the default) and
#'   `"r"` both use the pure-R/DuckDB implementation. `"rust"` uses the
#'   compiled library and is **deprecated**: it writes an unsorted index and
#'   supports neither `columns` nor `add_columns`. It will be removed in a
#'   future release. `"auto"` (the default) uses the
#'   compiled Rust library when it is loaded and the pure-R/DuckDB
#'   implementation otherwise, so behaviour is unchanged for an installed
#'   binary. `"r"` forces pure R and is always available. `"rust"` forces the
#'   compiled path and errors if it is not loaded.
#'
#' @return When `corpus_dir` is provided, invisibly returns the path to the
#'   created index file. When `root_dir` is used, invisibly returns `root_dir`.
#'
#' @details A hive-partitioned directory, not a single file:
#'
#' ```
#' works_id_idx/
#'   _index_meta.parquet
#'   id_block=0/part-0.parquet
#'   ...
#' ```
#'
#' with `id_block = floor(numeric_id / block_size)`, each part sorted by `id`,
#' holding `id` (long form), `parquet_file` (relative to the parquet root) and
#' `file_row_number` (0-indexed).
#'
#' A single file measured 3,992 row groups whose footer cost 0.192 s to parse
#' before reading any data, on every query, and needed a global sort of 492M
#' rows to build. Partitioning removes both: blocks sort independently, and a
#' lookup opens only the blocks its ids fall in.
#'
#' `_index_meta.parquet` is written last; its presence marks the index
#' complete, and it records the `block_size` the query side must recompute.
#'
#' @seealso [lookup_by_id()] for ID-based record retrieval,
#'   [build_citation_index()] and [build_doi_index()].
#'
#' @export
build_corpus_index <- function(
  root_dir     = NULL,
  data_sets    = NULL,
  workers      = NULL,
  memory_limit = NULL,
  temp_dir     = NULL,
  batch_bytes  = 1e9,
  block_size   = NULL,
  overwrite    = FALSE,
  verbose      = TRUE,
  corpus_dir   = NULL,
  backend      = c("auto", "r", "rust")
) {
  backend          <- .oas_backend(backend)

  build_one <- function(dir) {
    .oas_build_one_index(
      corpus_dir   = dir,
      workers      = workers,
      memory_limit = memory_limit,
      temp_dir     = temp_dir,
      batch_bytes  = batch_bytes,
      block_size   = block_size,
      overwrite    = isTRUE(overwrite),
      verbose      = isTRUE(verbose)
    )
  }

  # corpus_dir mode: index a single explicit directory -------------------------
  if (!is.null(corpus_dir)) {
    return(invisible(build_one(corpus_dir)))
  }

  # root_dir mode: iterate over datasets ---------------------------------------
  if (is.null(root_dir)) {
    stop(
      "Provide either `root_dir` or `corpus_dir`.",
      call. = FALSE
    )
  }

  parquet_root <- .oas_parquet_root(root_dir)

  if (is.null(data_sets)) {
    data_sets <- list.dirs(parquet_root, recursive = FALSE, full.names = FALSE)
    data_sets <- data_sets[!grepl("^\\.", data_sets)]
  }

  for (ds in data_sets) {
    build_one(file.path(parquet_root, ds))
  }

  invisible(root_dir)
}
