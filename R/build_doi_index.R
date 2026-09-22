#' Build a Parquet DOI-lookup index
#'
#' Builds a `<dataset>_doi_idx.parquet` index mapping normalised DOIs to
#' OpenAlex IDs and to their location in the Parquet corpus, so DOIs can be
#' resolved without network access.
#'
#' The corpus stores DOIs as full lower-cased resolver URLs
#' (`https://doi.org/10.1097/...`). The index key is the **bare** DOI, so that
#' a caller may supply any of these and get the same answer:
#'
#' ```
#' 10.1016/j.joi.2017.08.007
#' https://doi.org/10.1016/j.joi.2017.08.007
#' http://dx.doi.org/10.1016/j.joi.2017.08.007
#' doi:10.1016/j.joi.2017.08.007
#' DOI: 10.1016/J.JOI.2017.08.007
#' ```
#'
#' Carrying `parquet_file` and `file_row_number` alongside the ID means
#' [lookup_by_doi()] can extract full records from one index read rather than
#' two.
#'
#' @param root_dir Root directory containing a `parquet/` subdirectory, or the
#'   parquet directory itself.
#' @param data_sets Datasets to index. Only `works` carries a `doi` column, so
#'   the default is `"works"`.
#' @param workers Number of parallel workers for Stage 1.
#' @param memory_limit DuckDB memory limit, e.g. `"20GB"`.
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
#' @param compression Parquet compression codec.
#' @param overwrite Rebuild an existing index.
#' @param verbose Print progress.
#' @param corpus_dir Explicit path to a single dataset Parquet directory. When
#'   given, `root_dir` and `data_sets` are ignored.
#'
#' @return Invisibly, the path to the index file (`corpus_dir` mode) or
#'   `root_dir`.
#'
#' @details The index contains:
#' \describe{
#'   \item{doi}{Normalised bare lower-case DOI, no resolver prefix}
#'   \item{id}{OpenAlex ID in long form}
#'   \item{id_block}{`floor(numeric_id / 10000)`, as in the ID index}
#'   \item{parquet_file}{Path relative to the parquet root}
#'   \item{file_row_number}{Row number within that file (0-indexed)}
#' }
#'
#' Rows are sorted by `doi`, so a point lookup reads the footer plus one row
#' group rather than scanning the file.
#'
#' @seealso [doi_to_id()], [lookup_by_doi()], [build_corpus_index()]
#' @export
build_doi_index <- function(root_dir = NULL,
                            data_sets = "works",
                            workers = NULL,
                            memory_limit = NULL,
                            temp_dir = NULL,
                            batch_bytes = 8e9,
                            compression = "zstd",
                            overwrite = FALSE,
                            verbose = TRUE,
                            corpus_dir = NULL) {
  build_one <- function(dir) {
    .oas_build_one_doi_index(
      corpus_dir = dir, workers = workers, memory_limit = memory_limit,
      temp_dir = temp_dir, batch_bytes = batch_bytes,
      compression = compression, overwrite = overwrite, verbose = verbose
    )
  }

  if (!is.null(corpus_dir)) return(invisible(build_one(corpus_dir)))
  if (is.null(root_dir)) {
    stop("Provide either `root_dir` or `corpus_dir`.", call. = FALSE)
  }

  parquet_root <- .oas_parquet_root(root_dir)
  for (ds in data_sets) build_one(file.path(parquet_root, ds))
  invisible(root_dir)
}

#' @noRd
.oas_build_one_doi_index <- function(corpus_dir,
                                     workers = NULL,
                                     memory_limit = NULL,
                                     temp_dir = NULL,
                                     batch_bytes = 8e9,
                                     compression = "zstd",
                                     overwrite = FALSE,
                                     verbose = TRUE) {
  if (!dir.exists(corpus_dir)) {
    stop("corpus_dir does not exist: ", corpus_dir, call. = FALSE)
  }
  corpus_dir  <- normalizePath(corpus_dir)
  parent_dir  <- dirname(corpus_dir)
  corpus_name <- basename(corpus_dir)
  index_file  <- file.path(parent_dir, paste0(corpus_name, "_doi_idx.parquet"))

  if (file.exists(index_file)) {
    if (!isTRUE(overwrite)) {
      message("index_file exists - creation skipped",
              " - delete manually or use overwrite = TRUE to re-create: ",
              index_file)
      return(invisible(index_file))
    }
    unlink(index_file)
  }

  files <- .oas_corpus_files(corpus_dir)

  # Fail early and clearly on a dataset with no doi column.
  probe <- .oas_con()
  has_doi <- tryCatch({
    cols <- DBI::dbGetQuery(probe, paste0(
      "SELECT column_name FROM (DESCRIBE SELECT * FROM read_parquet(",
      .oas_sql_str(.oas_fwd(files[1L])), ") LIMIT 0)"))$column_name
    "doi" %in% cols
  }, finally = DBI::dbDisconnect(probe, shutdown = TRUE))
  if (!has_doi) {
    stop("Dataset '", corpus_name, "' has no `doi` column; ",
         "only works can be DOI-indexed.", call. = FALSE)
  }

  if (is.null(temp_dir)) {
    temp_dir <- file.path(tempdir(), paste0(corpus_name, "_doi_idx_tmp"))
  }
  dir.create(temp_dir, recursive = TRUE, showWarnings = FALSE)
  batches <- .oas_plan_batches(files, batch_bytes = batch_bytes)
  total_start <- Sys.time()

  if (isTRUE(verbose)) {
    message("Building DOI index from: ", corpus_dir)
    message("    Writing to: ", index_file)
    message("Stage 1: ", length(files), " files in ", length(batches),
            " batches ...")
  }

  # One DuckDB thread per worker when running in parallel -- the processes
  # already saturate the machine. Running sequentially, let DuckDB use all
  # cores rather than idling them.
  wthreads <- if (!is.null(workers) && workers > 1L) 1L else NULL

  if (!is.null(workers) && workers > 1L) {
    old_plan <- future::plan(future::multisession, workers = workers)
    on.exit(future::plan(old_plan), add = TRUE)
  }

  root_prefix <- paste0(.oas_fwd(parent_dir), "/")

  progressr::with_progress(
    {
      p <- progressr::progressor(along = batches)
      future.apply::future_lapply(seq_along(batches), function(i) {
        out_file <- file.path(temp_dir, sprintf("doi_%05d.parquet", i))
        if (file.exists(out_file)) {          # resume
          p()
          return(invisible(NULL))
        }
        # Private spill directory per worker: concurrent DuckDB instances
        # sharing one temp_directory corrupt each other's spill files.
        wcon <- .oas_con(memory_limit = memory_limit,
                         temp_dir = file.path(temp_dir, "duckdb", sprintf("doi_%05d", i)),
                         threads = wthreads)
        on.exit(DBI::dbDisconnect(wcon, shutdown = TRUE), add = TRUE)

        # This normalisation must agree exactly with .oas_normalize_doi();
        # test-build_doi_index.R asserts the round trip.
        q <- paste0(
          "COPY (SELECT ",
          "  lower(regexp_replace(w.doi, '^https?://(dx\\.)?doi\\.org/', '')) AS doi, ",
          "  w.id AS id, ",
          "  CAST(FLOOR(CAST(regexp_extract(w.id, '(\\d+)$', 1) AS BIGINT) / 10000)",
          "       AS INTEGER) AS id_block, ",
          "  replace(replace(w.filename, ", .oas_sql_str(root_prefix), ", ''),",
          "          '\\', '/') AS parquet_file, ",
          "  w.file_row_number AS file_row_number ",
          "FROM read_parquet(", .oas_sql_paths(batches[[i]]),
          ", filename = true, file_row_number = true, hive_partitioning = false) AS w ",
          "WHERE w.doi IS NOT NULL AND w.doi <> ''",
          ") TO ", .oas_sql_str(.oas_fwd(out_file)),
          " (FORMAT PARQUET, COMPRESSION ", toupper(compression), ")"
        )
        DBI::dbExecute(wcon, q)
        p()
        invisible(NULL)
      }, future.seed = TRUE)
    },
    handlers = progressr::handler_cli()
  )

  if (isTRUE(verbose)) {
    message("    Stage 1 complete.")
    message("Stage 2: sorting by doi into ", index_file,
            " (this spills to ", temp_dir, ")")
  }

  # preserve_insertion_order = TRUE so the ORDER BY survives into the file;
  # without it the row-group min/max on doi are useless and every lookup
  # degrades to a full scan.
  con <- .oas_con(memory_limit = memory_limit, temp_dir = temp_dir,
                  threads = workers, preserve_order = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  DBI::dbExecute(con, paste0(
    "COPY (SELECT doi, id, id_block, parquet_file, file_row_number ",
    "FROM read_parquet(",
    .oas_sql_str(paste0(.oas_fwd(temp_dir), "/doi_*.parquet")),
    ") ORDER BY doi) TO ", .oas_sql_str(.oas_fwd(index_file)),
    " (FORMAT PARQUET, COMPRESSION ", toupper(compression),
    ", ROW_GROUP_SIZE 200000)"
  ))

  unlink(temp_dir, recursive = TRUE)

  if (isTRUE(verbose)) {
    message("Done! Index size: ",
            round(file.info(index_file)$size / 1024^3, 3), " GB")
    message("Total time: ",
            round(difftime(Sys.time(), total_start, units = "mins"), 2),
            " minutes")
  }
  invisible(index_file)
}
