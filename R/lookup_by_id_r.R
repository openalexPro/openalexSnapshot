# lookup_by_id_r ---
# Pure-R/DuckDB implementation behind lookup_by_id(backend = "r").
#
# Recovered from openalexPro 70539a0:R/lookup_by_id.R (.lookup_one_index).
# Changes from that version:
#   * `columns` — project a subset of columns instead of always SELECT *.
#     Reading 2 of 51 columns from a corpus of deeply nested structs is the
#     difference between seconds and minutes; the Rust path cannot do this.
#   * `add_columns` — inject constant columns, emitted as single-quoted SQL
#     string literals to match openalexPro::pro_request_parquet(). That is what
#     lets openalexSnowball run one shared node-assembly step across the API
#     and snapshot paths.

#' Look up records by ID in pure R
#'
#' @inheritParams lookup_by_id
#' @return A data frame, or invisibly `output` when writing to disk.
#' @noRd
.oas_lookup_one_index <- function(index_file,
                                  ids,
                                  columns = NULL,
                                  add_columns = NULL,
                                  selected = NULL,
                                  workers = NULL,
                                  memory_limit = NULL,
                                  temp_dir = NULL,
                                  output = NULL,
                                  verbose = TRUE) {
  index_file <- normalizePath(index_file, mustWork = FALSE)
  .oas_require_index(index_file, "id", "build_corpus_index")
  snapshot_path <- dirname(index_file)
  meta <- .oas_read_index_meta(index_file)

  if (!is.null(output) && dir.exists(output)) {
    stop("Output directory already exists: ", output, call. = FALSE)
  }

  ids <- .oas_normalize_id(ids)
  if (isTRUE(verbose)) message("Looking up ", length(ids), " ids ...")

  # Build the partition file list in R rather than globbing the whole index.
  # Globbing opens every partition footer, which is exactly the cost the
  # partitioned layout exists to avoid: the old single-file index carried 3,992
  # row groups and cost 0.192 s just to parse before reading anything.
  block_size <- if (is.null(meta)) 1e7 else as.numeric(meta$block_size[[1L]])
  blocks <- unique(floor(.oas_id_numeric(ids) / block_size))
  parts  <- file.path(index_file, sprintf("id_block=%d", blocks), "part-0.parquet")
  parts  <- parts[file.exists(parts)]
  if (length(parts) == 0L) {
    if (isTRUE(verbose)) message("No matching records found in index")
    if (!is.null(output)) return(invisible(output))
    return(data.frame())
  }

  matches <- arrow::open_dataset(parts, format = "parquet") |>
    dplyr::filter(.data$id %in% ids) |>
    dplyr::collect()

  if (is.null(matches) || nrow(matches) == 0L) {
    if (isTRUE(verbose)) message("No matching records found in index")
    if (!is.null(output)) return(invisible(output))
    return(data.frame())
  }
  if (isTRUE(verbose)) {
    message("Found ", nrow(matches), " matching records in index")
  }

  if (!is.null(selected)) {
    arrow::write_dataset(matches, path = selected, format = "parquet",
                         partitioning = "parquet_file")
  }

  # SELECT list: projection + constant columns --------------------------------
  sel <- if (is.null(columns)) {
    "*"
  } else {
    paste(sprintf('"%s"', gsub('"', '""', columns, fixed = TRUE)), collapse = ", ")
  }
  if (!is.null(add_columns)) {
    if (is.null(names(add_columns)) || any(!nzchar(names(add_columns)))) {
      stop("`add_columns` must be a named list.", call. = FALSE)
    }
    extras <- sprintf("%s AS \"%s\"",
                      .oas_sql_str(unlist(add_columns, use.names = FALSE)),
                      names(add_columns))
    sel <- paste(c(sel, extras), collapse = ", ")
  }

  if (!is.null(workers) && workers > 1L) {
    old_plan <- future::plan(future::multisession, workers = workers)
    on.exit(future::plan(old_plan), add = TRUE)
  }

  file_chunks <- split(matches$file_row_number, matches$parquet_file)
  names(file_chunks) <- .oas_fwd(file.path(snapshot_path, names(file_chunks)))

  if (isTRUE(verbose)) {
    message("Reading from ", length(file_chunks), " parquet file(s) ...")
  }

  oopts <- options(future.globals.maxSize = 1e9)
  on.exit(options(oopts), add = TRUE)
  if (!is.null(output)) dir.create(output, recursive = TRUE, showWarnings = FALSE)

  progressr::with_progress(
    {
      p <- progressr::progressor(along = file_chunks)
      results <- future.apply::future_lapply(names(file_chunks), function(pq) {
        rows <- paste(file_chunks[[pq]], collapse = ", ")
        # Each worker needs its OWN spill directory. DuckDB's default is
        # `.tmp` relative to the working directory, which every worker in the
        # pool inherits -- they then write colliding duckdb_temp_storage_*.tmp
        # files and corrupt each other's spill. This is the same hazard
        # build_citation_index() documents; it was missing here.
        wtmp <- file.path(
          temp_dir %||% file.path(tempdir(), "oas_lookup"),
          gsub("[^A-Za-z0-9._-]", "_", basename(pq))
        )
        wcon <- .oas_con(memory_limit = memory_limit, temp_dir = wtmp,
                         threads = 1L)
        on.exit(DBI::dbDisconnect(wcon, shutdown = TRUE), add = TRUE)
        on.exit(unlink(wtmp, recursive = TRUE, force = TRUE), add = TRUE)

        body <- paste0(
          "SELECT ", sel, " FROM read_parquet(", .oas_sql_str(pq),
          ", file_row_number = true, hive_partitioning = false) ",
          "WHERE file_row_number IN (", rows, ")"
        )
        out <- if (!is.null(output)) {
          of <- file.path(output, paste0("part_", basename(pq)))
          tryCatch({
            DBI::dbExecute(wcon, paste0(
              "COPY (", body, ") TO ", .oas_sql_str(.oas_fwd(of)),
              " (FORMAT PARQUET, COMPRESSION SNAPPY)"
            ))
            length(file_chunks[[pq]])
          }, error = function(e) {
            warning("Failed to write from ", pq, ": ", conditionMessage(e))
            0L
          })
        } else {
          tryCatch(DBI::dbGetQuery(wcon, body), error = function(e) {
            warning("Failed to read from ", pq, ": ", conditionMessage(e))
            data.frame()
          })
        }
        p()
        out
      }, future.seed = TRUE)
    },
    handlers = progressr::handler_cli()
  )

  if (!is.null(output)) {
    if (isTRUE(verbose)) {
      message("Written ", sum(unlist(results)), " records to ", output)
    }
    return(invisible(output))
  }

  result <- do.call(rbind, results)
  if ("file_row_number" %in% names(result)) result$file_row_number <- NULL
  if (isTRUE(verbose)) message("Retrieved ", nrow(result), " records")
  result
}
