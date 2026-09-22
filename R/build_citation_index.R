#' Build an inverted citation index
#'
#' Inverts the `referenced_works` column of the works corpus into an edge set
#' keyed by the **cited** work, so that "which works cite X?" becomes a point
#' lookup instead of a full-corpus scan. This is what makes [get_citing()]
#' possible offline: the snapshot's `cited_by_api_url` is a URL and useless
#' without network access, but the citing direction is recoverable by
#' inverting the references every work already carries.
#'
#' [get_cited()] does **not** need this index -- the works a paper references
#' are simply its own `referenced_works` -- so only one index is built, not a
#' pair.
#'
#' @section Layout:
#' Like `<dataset>_id_idx/`, this index is a **hive-partitioned directory**
#' (only `<dataset>_doi_idx.parquet` remains a single file):
#'
#' ```
#' works_cite_idx/
#'   _index_meta.parquet
#'   cited_block=0/part-0.parquet
#'   cited_block=1/part-0.parquet
#'   ...
#' ```
#'
#' The reason is scale. The full OpenAlex works corpus holds roughly three
#' billion reference edges; a single sorted file would need a global sort of
#' that many rows, and its footer alone would cost tens of megabytes to parse
#' on every query. Partitioning by a coarse block of the cited ID keeps each
#' part small enough to sort in memory and lets a lookup open only the handful
#' of parts it needs.
#'
#' `_index_meta.parquet` is written **last**; its presence is what marks the
#' index complete, and it records the `block_size` the query side must use.
#'
#' @param root_dir Root directory containing a `parquet/` subdirectory, or the
#'   parquet directory itself.
#' @param data_sets Datasets to index. Only works carry `referenced_works`, so
#'   the default is `"works"`.
#' @param workers Number of parallel workers.
#' @param memory_limit DuckDB memory limit per worker, e.g. `"8GB"`.
#' @param retry_memory_limit Memory limit for the sequential retry of batches
#'   that exceeded `memory_limit` during the parallel pass. Peak memory depends
#'   on how reference-dense a batch's works happen to be, which varies enough
#'   across the corpus that no single per-worker limit suits every batch;
#'   rather than sizing `memory_limit` for the worst batch and throttling all
#'   of them, dense batches are re-run alone with the whole machine.
#' @param temp_dir Directory for Stage-1 shards and DuckDB spill. Defaults to a
#'   subdirectory of [tempdir()], which is on local disk.
#'
#'   The default matters. Spilling beside the index puts those writes on the
#'   same device the corpus is being read from, and on an external USB SSD that
#'   measured **8.18 s/batch versus 0.76 s/batch** -- a 10.8x difference from
#'   this setting alone. Override it only to point at a *different* fast disk,
#'   or if the default lacks room: peak usage is roughly the size of the
#'   finished index plus its transient shards.
#' @param block_size Width of a `cited_block`. The default `1e7` yields ~351
#'   partitions over the full corpus, averaging tens of MB each. Do **not** use
#'   the ID index's `floor(n / 1e4)`: the largest OpenAlex work ID would give
#'   over 700,000 partitions.
#' @param batch_bytes Approximate bytes of source parquet per Stage-1 batch.
#'   Batching is by byte budget over the flat file list rather than by hive
#'   partition, because the corpus is extremely skewed -- one `updated_date=`
#'   partition can hold half the works while hundreds hold megabytes.
#'
#'   The default of 1 GB is measured, not guessed. Unnesting a batch and
#'   writing it across hundreds of partitions costs far more memory than the
#'   few MB it emits, so the batch size governs spill. On the dense files of
#'   the real corpus, at `memory_limit = "3GB"`: a 1 GB batch takes ~2.4 s with
#'   **no spill**; a 2 GB batch takes ~15 s; a 4 GB batch runs **out of
#'   memory**. An earlier 8 GB default spilled 23-31 GB per batch and was
#'   roughly six times slower overall. Raise this only alongside
#'   `memory_limit`, and measure.
#' @param compression Parquet compression codec.
#' @param overwrite Rebuild an existing index.
#' @param verbose Print progress.
#' @param corpus_dir Explicit path to a single dataset Parquet directory.
#'
#' @return Invisibly, the path to the index directory (`corpus_dir` mode) or
#'   `root_dir`.
#'
#' @details Each part file holds:
#' \describe{
#'   \item{cited_id}{The cited work's OpenAlex ID, long form `VARCHAR`}
#'   \item{citing_id}{The citing work's OpenAlex ID, long form `VARCHAR`}
#' }
#' sorted by `(cited_id, citing_id)`, matching the long-form convention of
#' `<dataset>_id_idx/` and `<dataset>_doi_idx.parquet` so every index in the
#' family stores IDs the same way. Note this costs real space at three
#' billion rows: `citing_id` is effectively random within a block and so does
#' not dictionary-compress, unlike the sorted `cited_id`.
#'
#' @seealso [get_citing()], [get_cited()]
#' @export
build_citation_index <- function(root_dir = NULL,
                                 data_sets = "works",
                                 workers = NULL,
                                 memory_limit = NULL,
                                 retry_memory_limit = "12GB",
                                 temp_dir = NULL,
                                 block_size = 1e7,
                                 batch_bytes = 1e9,
                                 compression = "zstd",
                                 overwrite = FALSE,
                                 verbose = TRUE,
                                 corpus_dir = NULL) {
  build_one <- function(dir) {
    .oas_build_one_citation_index(
      corpus_dir = dir, workers = workers, memory_limit = memory_limit,
      retry_memory_limit = retry_memory_limit,
      temp_dir = temp_dir, block_size = block_size, batch_bytes = batch_bytes,
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
.oas_build_one_citation_index <- function(corpus_dir,
                                          workers = NULL,
                                          memory_limit = NULL,
                                          retry_memory_limit = "12GB",
                                          temp_dir = NULL,
                                          block_size = 1e7,
                                          batch_bytes = 1e9,
                                          compression = "zstd",
                                          overwrite = FALSE,
                                          verbose = TRUE) {
  if (!dir.exists(corpus_dir)) {
    stop("corpus_dir does not exist: ", corpus_dir, call. = FALSE)
  }
  corpus_dir  <- normalizePath(corpus_dir)
  parent_dir  <- dirname(corpus_dir)
  corpus_name <- basename(corpus_dir)
  index_dir   <- file.path(parent_dir, paste0(corpus_name, "_cite_idx"))
  block_size  <- as.integer(block_size)
  comp        <- toupper(compression)

  complete <- file.exists(file.path(index_dir, "_index_meta.parquet"))
  if (dir.exists(index_dir) && complete && !isTRUE(overwrite)) {
    message("index exists - creation skipped",
            " - delete manually or use overwrite = TRUE to re-create: ",
            index_dir)
    return(invisible(index_dir))
  }
  if (isTRUE(overwrite)) unlink(index_dir, recursive = TRUE)

  files <- .oas_corpus_files(corpus_dir)
  if (is.null(temp_dir)) {
    temp_dir <- file.path(tempdir(), paste0(corpus_name, "_cite_idx_tmp"))
  }
  shards_dir <- file.path(temp_dir, "shards")
  done_dir   <- file.path(temp_dir, ".done")
  dir.create(shards_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(done_dir,   recursive = TRUE, showWarnings = FALSE)

  sniff_con <- .oas_con()
  refs <- tryCatch(.oas_refs_expr(sniff_con, files, alias = "w"),
                   finally = DBI::dbDisconnect(sniff_con, shutdown = TRUE))

  # Peak usage is the finished index plus its transient shards. Measured on the
  # real corpus: 900 GB of source produced an 18.4 GB index, so ~2% of source
  # each for index and shards, plus spill headroom.
  .oas_check_space(temp_dir,
                   need_bytes = 0.05 * sum(file.info(files)$size, na.rm = TRUE),
                   what = "citation index")

  batches <- .oas_plan_batches(files, batch_bytes = batch_bytes)
  total_start <- Sys.time()

  if (isTRUE(verbose)) {
    message("Building citation index from: ", corpus_dir)
    message("    Writing to: ", index_dir)
    message("    referenced_works encoding: ", refs$enc)
    message("Stage 1: ", length(files), " files in ", length(batches),
            " batches, block_size = ", format(block_size, scientific = FALSE))
  }

  # One DuckDB thread per worker when running in parallel -- the processes
  # already saturate the machine. Running sequentially, let DuckDB use all
  # cores rather than idling them.
  wthreads <- if (!is.null(workers) && workers > 1L) 1L else NULL

  if (!is.null(workers) && workers > 1L) {
    old_plan <- future::plan(future::multisession, workers = workers)
    on.exit(future::plan(old_plan), add = TRUE)
  }

  # Stage 1: extract edges, range-partition by cited_block ---------------------
  failed <- progressr::with_progress(
    {
      p <- progressr::progressor(along = batches)
      unlist(future.apply::future_lapply(seq_along(batches), function(i) {
        tag    <- sprintf("b%05d", i)
        marker <- file.path(done_dir, tag)
        if (file.exists(marker)) {          # resume
          p()
          return(invisible(NULL))
        }
        # A partitioned COPY writes many files, so file existence is not a
        # completion marker. Clear any partial output from an interrupted run;
        # FILENAME_PATTERN is what makes those files identifiable (and what
        # makes concurrent writes into one shard tree safe).
        partial <- list.files(shards_dir, pattern = paste0("^", tag, "_"),
                              recursive = TRUE, full.names = TRUE)
        if (length(partial)) unlink(partial)

        # Each worker needs its OWN DuckDB spill directory. Concurrent DuckDB
        # instances sharing one temp_directory write colliding
        # duckdb_temp_storage_*.tmp files and corrupt each other's spill.
        wcon <- .oas_con(memory_limit = memory_limit,
                         temp_dir = file.path(temp_dir, "duckdb", tag),
                         threads = wthreads, preserve_order = FALSE)
        on.exit(DBI::dbDisconnect(wcon, shutdown = TRUE), add = TRUE)
        # Default is 100, which is below the partition count; leaving it there
        # makes DuckDB rotate files and emit far more shards than expected.
        DBI::dbExecute(wcon, "SET partitioned_write_max_open_files = 512")
        # Stage-1 shards are throwaway input to Stage 2, so row-group size is
        # irrelevant to read performance here -- but on a write fanned out over
        # hundreds of partitions DuckDB sizes its per-partition buffers from it,
        # and a large value is what pushes a dense batch out of memory. Keep it
        # small; Stage 2 sets the size that actually matters.

        q <- .oas_stage1_sql(batches[[i]], refs$expr, block_size, shards_dir,
                             tag, comp)
        ok <- tryCatch({ DBI::dbExecute(wcon, q); TRUE },
                       error = function(e) conditionMessage(e))
        if (isTRUE(ok)) file.create(marker)
        p()
        if (isTRUE(ok)) NA_integer_ else i
      }, future.seed = TRUE))
    },
    handlers = progressr::handler_cli()
  )
  failed <- failed[!is.na(failed)]

  # Retry stragglers sequentially with the whole machine to themselves.
  #
  # Peak memory for a batch scales with how reference-dense its works happen to
  # be, which varies enough across 492M heterogeneous records that no fixed
  # per-worker limit is safe for every batch. Rather than sizing the limit for
  # the worst batch -- which would throttle all 1200 of them -- let dense
  # batches fail and re-run just those with the full memory budget and no
  # competing workers.
  if (length(failed)) {
    if (isTRUE(verbose)) {
      message("    ", length(failed), " batch(es) exceeded the per-worker ",
              "memory limit; retrying sequentially ...")
    }
    future::plan(future::sequential)
    for (i in failed) {
      tag <- sprintf("b%05d", i)
      partial <- list.files(shards_dir, pattern = paste0("^", tag, "_"),
                            recursive = TRUE, full.names = TRUE)
      if (length(partial)) unlink(partial)
      rcon <- .oas_con(memory_limit = retry_memory_limit,
                       temp_dir = file.path(temp_dir, "duckdb", tag),
                       threads = NULL, preserve_order = FALSE)
      DBI::dbExecute(rcon, "SET partitioned_write_max_open_files = 512")
      res <- tryCatch({ DBI::dbExecute(rcon, .oas_stage1_sql(
                          batches[[i]], refs$expr, block_size, shards_dir, tag, comp))
                        TRUE },
                      error = function(e) conditionMessage(e))
      DBI::dbDisconnect(rcon, shutdown = TRUE)
      if (isTRUE(res)) {
        file.create(file.path(done_dir, tag))
      } else {
        stop("Batch ", i, " failed even on a sequential retry with ",
             retry_memory_limit, ": ", res,
             "\nLower `batch_bytes` and re-run; completed batches are resumed.",
             call. = FALSE)
      }
    }
  }

  # Stage 2: sort/merge each block. No global sort. ---------------------------
  blocks <- list.dirs(shards_dir, recursive = FALSE, full.names = FALSE)
  blocks <- blocks[grepl("^cited_block=", blocks)]
  if (length(blocks) == 0L) {
    stop("No edges were extracted; is `referenced_works` empty throughout?",
         call. = FALSE)
  }
  dir.create(index_dir, recursive = TRUE, showWarnings = FALSE)

  if (isTRUE(verbose)) {
    message("    Stage 1 complete.")
    message("Stage 2: sorting ", length(blocks), " blocks ...")
  }

  n_edges <- progressr::with_progress(
    {
      p <- progressr::progressor(along = blocks)
      unlist(future.apply::future_lapply(blocks, function(b) {
        out_sub <- file.path(index_dir, b)
        dir.create(out_sub, recursive = TRUE, showWarnings = FALSE)
        out_file <- file.path(out_sub, "part-0.parquet")

        # preserve_insertion_order = TRUE is required here: without it the
        # parallel writer may emit row groups out of order and the row-group
        # min/max on cited_id -- the whole basis of the fast lookup -- become
        # useless. It is deliberately FALSE in Stage 1, where order is
        # irrelevant.
        wcon <- .oas_con(memory_limit = memory_limit,
                         temp_dir = file.path(temp_dir, "duckdb", b),
                         threads = wthreads, preserve_order = TRUE)
        on.exit(DBI::dbDisconnect(wcon, shutdown = TRUE), add = TRUE)

        src <- .oas_sql_str(paste0(.oas_fwd(file.path(shards_dir, b)), "/*.parquet"))
        DBI::dbExecute(wcon, paste0(
          "COPY (SELECT DISTINCT cited_id, citing_id FROM read_parquet(", src,
          ", hive_partitioning = false) ORDER BY cited_id, citing_id) TO ",
          .oas_sql_str(.oas_fwd(out_file)),
          " (FORMAT PARQUET, COMPRESSION ", comp, ", ROW_GROUP_SIZE 200000)"
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

  # Metadata sidecar, written last: its presence marks the index complete.
  .oas_write_index_meta(index_dir, data.frame(
    index_type      = "citation",
    corpus_dir      = corpus_dir,
    block_size      = block_size,
    ref_encoding    = refs$enc,
    n_source_files  = length(files),
    source_bytes    = sum(file.info(files)$size, na.rm = TRUE),
    n_edges         = sum(n_edges),
    n_blocks        = length(blocks),
    built_at        = Sys.time(),
    builder_version = as.character(utils::packageVersion("openalexSnapshot")),
    stringsAsFactors = FALSE
  ))

  unlink(temp_dir, recursive = TRUE)

  if (isTRUE(verbose)) {
    sz <- sum(file.info(list.files(index_dir, recursive = TRUE,
                                   full.names = TRUE))$size, na.rm = TRUE)
    message("Done! ", format(sum(n_edges), big.mark = ","), " edges in ",
            length(blocks), " blocks, ", round(sz / 1024^3, 3), " GB (",
            round(sz / max(sum(n_edges), 1), 2), " bytes/edge)")
    message("Total time: ",
            round(difftime(Sys.time(), total_start, units = "mins"), 2),
            " minutes")
  }
  invisible(index_dir)
}

#' Stage-1 extraction statement
#'
#' Shared by the parallel pass and the sequential retry so the two cannot drift.
#' @noRd
.oas_stage1_sql <- function(files, refs_expr, block_size, shards_dir, tag, comp) {
  # IDs are stored as long-form strings for consistency with
  # <dataset>_id_idx/ and <dataset>_doi_idx.parquet, which both use
  # 'https://openalex.org/W...'. The numeric form is still derived here, but
  # only to compute cited_block; it is not stored.
  paste0(
    "COPY (SELECT cited_id, citing_id, ",
    "  CAST(cited_num // ", block_size, " AS INTEGER) AS cited_block ",
    "FROM (SELECT ",
    "   'https://openalex.org/W' || substr(r.ref, position('/W' IN r.ref) + 2) AS cited_id, ",
    "   'https://openalex.org/W' || substr(w.id , position('/W' IN w.id ) + 2) AS citing_id, ",
    "   TRY_CAST(substr(r.ref, position('/W' IN r.ref) + 2) AS UBIGINT) AS cited_num ",
    " FROM read_parquet(", .oas_sql_paths(files),
    ", hive_partitioning = false) AS w, ",
    " LATERAL UNNEST(", refs_expr, ") AS r(ref) ",
    " WHERE w.referenced_works IS NOT NULL) ",
    "WHERE cited_num IS NOT NULL AND citing_id IS NOT NULL",
    ") TO ", .oas_sql_str(.oas_fwd(shards_dir)),
    " (FORMAT PARQUET, COMPRESSION ", comp,
    ", PARTITION_BY (cited_block)",
    ", FILENAME_PATTERN ", .oas_sql_str(paste0(tag, "_{i}")),
    ", OVERWRITE_OR_IGNORE, ROW_GROUP_SIZE 100000)"
  )
}
