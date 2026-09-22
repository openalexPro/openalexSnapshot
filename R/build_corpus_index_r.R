# build_corpus_index_r ---
# Pure-R/DuckDB implementation behind build_corpus_index(backend = "r").
#
# Recovered from openalexPro 70539a0:R/build_corpus_index.R (.build_one_index),
# where it was a working, validated implementation before the Rust rewrite.
# Changes from that version:
#   * `filename = true` replaces the per-file R-side relative-path computation,
#     so Stage 1 issues one statement per batch instead of one per file. This
#     also removes the Windows 8.3 short-name path-depth workaround.
#   * ZSTD instead of SNAPPY (smaller index, same read speed).
#   * Connection setup goes through .oas_con().

#' Build one ID index in pure R
#'
#' Two stages, mirroring [build_citation_index()]: Stage 1 extracts and
#' range-partitions by `id_block` (parallel, resumable), Stage 2 sorts each
#' block independently.
#'
#' The output is a hive **directory**, not a single file. A single file needed
#' a global sort of 492M rows, and carried 3,992 row groups whose footer had to
#' be parsed on every query -- 0.192 s before touching any data. Partitioning
#' removes both: each block sorts in memory, and a lookup opens only the blocks
#' its ids fall in, never parsing the other footers at all.
#'
#' @inheritParams build_corpus_index
#' @param corpus_dir Single dataset Parquet directory.
#' @return Invisibly, the path to the index file.
#' @noRd
.oas_build_one_index <- function(corpus_dir,
                                 workers = NULL,
                                 memory_limit = NULL,
                                 temp_dir = NULL,
                                 batch_bytes = 1e9,
                                 block_size = NULL,
                                 overwrite = FALSE,
                                 verbose = TRUE) {
  if (!dir.exists(corpus_dir)) {
    stop("corpus_dir does not exist: ", corpus_dir, call. = FALSE)
  }

  corpus_dir  <- normalizePath(corpus_dir)
  parent_dir  <- dirname(corpus_dir)
  corpus_name <- basename(corpus_dir)
  index_dir   <- file.path(parent_dir, paste0(corpus_name, "_id_idx"))

  complete <- file.exists(file.path(index_dir, "_index_meta.parquet"))
  if (dir.exists(index_dir) && complete && !isTRUE(overwrite)) {
    message("index exists - creation skipped",
            " - delete manually or use overwrite = TRUE to re-create: ",
            index_dir)
    return(invisible(index_dir))
  }
  if (isTRUE(overwrite)) unlink(index_dir, recursive = TRUE)

  files <- .oas_corpus_files(corpus_dir)
  if (is.null(block_size)) {
    block_size <- .oas_derive_block_size(files)
    if (isTRUE(verbose)) {
      message("    derived block_size = ", format(block_size, scientific = FALSE),
              " from the id range")
    }
  }
  block_size <- as.numeric(block_size)
  if (is.null(temp_dir)) {
    temp_dir <- file.path(tempdir(), paste0(corpus_name, "_id_idx_tmp"))
  }
  shards_dir <- file.path(temp_dir, "shards")
  done_dir   <- file.path(temp_dir, ".done")
  dir.create(shards_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(done_dir,   recursive = TRUE, showWarnings = FALSE)

  batches <- .oas_plan_batches(files, batch_bytes = batch_bytes)
  total_start <- Sys.time()

  if (isTRUE(verbose)) {
    message("Building index from: ", corpus_dir)
    message("    Writing to: ", index_dir)
    message("Stage 1: ", length(files), " parquet files in ",
            length(batches), " batches",
            if (!is.null(workers) && workers > 1L) {
              paste0(" with ", workers, " workers...")
            } else " sequentially...")
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
        tag    <- sprintf("b%05d", i)
        marker <- file.path(done_dir, tag)
        if (file.exists(marker)) {          # resume
          p()
          return(invisible(NULL))
        }
        partial <- list.files(shards_dir, pattern = paste0("^", tag, "_"),
                              recursive = TRUE, full.names = TRUE)
        if (length(partial)) unlink(partial)

        wcon <- .oas_con(memory_limit = memory_limit,
                         temp_dir = file.path(temp_dir, "duckdb", tag),
                         threads = wthreads, preserve_order = FALSE)
        on.exit(DBI::dbDisconnect(wcon, shutdown = TRUE), add = TRUE)
        DBI::dbExecute(wcon, "SET partitioned_write_max_open_files = 1024")

        q <- paste0(
          "COPY (SELECT ",
          "  w.id AS id, ",
          "  replace(replace(w.filename, ", .oas_sql_str(root_prefix), ", ''),",
          "          '\\', '/') AS parquet_file, ",
          "  w.file_row_number AS file_row_number, ",
          # Trailing digits, not position('/W'): that is works-only and yields
          # NULL for every author, source, institution and so on.
          "  CAST(TRY_CAST(regexp_extract(w.id, '([0-9]+)$', 1) AS UBIGINT)",
          "       // ", format(block_size, scientific = FALSE), " AS INTEGER) AS id_block ",
          "FROM read_parquet(", .oas_sql_paths(batches[[i]]),
          ", filename = true, file_row_number = true, hive_partitioning = false) AS w",
          ") TO ", .oas_sql_str(.oas_fwd(shards_dir)),
          " (FORMAT PARQUET, COMPRESSION ZSTD, PARTITION_BY (id_block)",
          ", FILENAME_PATTERN ", .oas_sql_str(paste0(tag, "_{i}")),
          ", OVERWRITE_OR_IGNORE, ROW_GROUP_SIZE 100000)"
        )
        DBI::dbExecute(wcon, q)
        file.create(marker)
        p()
        invisible(NULL)
      }, future.seed = TRUE)
    },
    handlers = progressr::handler_cli()
  )

  if (isTRUE(verbose)) message("    Stage 1 complete.")
  blocks <- grep("^id_block=", list.dirs(shards_dir, recursive = FALSE,
                                         full.names = FALSE), value = TRUE)
  if (length(blocks) == 0L) {
    stop("No index rows were produced from: ", corpus_dir, call. = FALSE)
  }
  dir.create(index_dir, recursive = TRUE, showWarnings = FALSE)

  if (isTRUE(verbose)) {
    message("    Stage 1 complete.")
    message("Stage 2: sorting ", length(blocks), " blocks ...")
  }

  n_rows <- progressr::with_progress(
    {
      p <- progressr::progressor(along = blocks)
      unlist(future.apply::future_lapply(blocks, function(b) {
        out_sub <- file.path(index_dir, b)
        dir.create(out_sub, recursive = TRUE, showWarnings = FALSE)
        out_file <- file.path(out_sub, "part-0.parquet")

        # preserve_insertion_order = TRUE so the ORDER BY survives into the
        # file; without it the row-group min/max on id are meaningless and
        # lookups degrade to scans.
        wcon <- .oas_con(memory_limit = memory_limit,
                         temp_dir = file.path(temp_dir, "duckdb", b),
                         threads = 1L, preserve_order = TRUE)
        on.exit(DBI::dbDisconnect(wcon, shutdown = TRUE), add = TRUE)

        src <- .oas_sql_str(paste0(.oas_fwd(file.path(shards_dir, b)), "/*.parquet"))
        DBI::dbExecute(wcon, paste0(
          "COPY (SELECT id, parquet_file, file_row_number FROM read_parquet(",
          src, ", hive_partitioning = false) ORDER BY id) TO ",
          .oas_sql_str(.oas_fwd(out_file)),
          " (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 200000)"
        ))
        n <- DBI::dbGetQuery(wcon, paste0(
          "SELECT count(*) AS n FROM read_parquet(",
          .oas_sql_str(.oas_fwd(out_file)), ")"))$n[[1L]]
        p()
        n
      }, future.seed = TRUE))
    },
    handlers = progressr::handler_cli()
  )

  # Written last: its presence marks the index complete, and it carries the
  # block_size the query side must recompute with.
  .oas_write_index_meta(index_dir, data.frame(
    index_type = "id", corpus_dir = corpus_dir, block_size = block_size,
    n_source_files = length(files),
    n_rows = sum(n_rows), n_blocks = length(blocks),
    built_at = Sys.time(),
    builder_version = as.character(utils::packageVersion("openalexSnapshot")),
    stringsAsFactors = FALSE
  ))

  unlink(temp_dir, recursive = TRUE)

  if (isTRUE(verbose)) {
    sz <- sum(file.info(list.files(index_dir, recursive = TRUE,
                                   full.names = TRUE))$size, na.rm = TRUE)
    message("Done! ", format(sum(n_rows), big.mark = ","), " rows in ",
            length(blocks), " blocks, ", round(sz / 1024^3, 3), " GB")
    message("Total time: ",
            round(difftime(Sys.time(), total_start, units = "mins"), 2),
            " minutes")
  }

  invisible(index_dir)
}
