# Tests for the inverted citation index.
# make_tiny_corpus() lives in helper.R.

test_that("build_citation_index() produces the documented layout and schema", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)

  idx <- build_citation_index(corpus_dir = corpus, verbose = FALSE)
  expect_true(dir.exists(idx))
  expect_match(idx, "works_cite_idx$")

  # a directory of hive partitions, not a single file
  parts <- list.files(idx, pattern = "part-0\\.parquet$", recursive = TRUE)
  expect_gt(length(parts), 1L)
  expect_true(all(grepl("^cited_block=[0-9]+/", parts)))

  edges <- dplyr::collect(arrow::open_dataset(
    list.files(idx, pattern = "part-0\\.parquet$", recursive = TRUE,
               full.names = TRUE)
  ))
  expect_setequal(names(edges), c("cited_id", "citing_id"))
  # long-form strings, matching works_id_idx.parquet and works_doi_idx.parquet
  expect_type(edges$cited_id, "character")
  expect_type(edges$citing_id, "character")
  expect_true(all(grepl("^https://openalex\\.org/W", edges$cited_id)))
  expect_true(all(grepl("^https://openalex\\.org/W", edges$citing_id)))
})

test_that("the edge set is exactly the unnested referenced_works", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_citation_index(corpus_dir = corpus, verbose = FALSE)

  src <- dplyr::collect(arrow::open_dataset(corpus))
  expected <- sum(vapply(src$referenced_works, function(x) {
    if (is.na(x) || x == "[]") 0L else lengths(regmatches(x, gregexpr("W[0-9]+", x)))
  }, integer(1)))

  meta <- .oas_read_index_meta(idx)
  expect_equal(as.numeric(meta$n_edges), as.numeric(expected))

  # NULL and "[]" referenced_works contribute nothing and do not error
  expect_gt(expected, 0L)
})

test_that("_index_meta.parquet records what the query side needs", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_citation_index(corpus_dir = corpus, block_size = 1e7,
                              verbose = FALSE)

  meta <- .oas_read_index_meta(idx)
  expect_false(is.null(meta))
  expect_equal(meta$index_type, "citation")
  expect_equal(as.numeric(meta$block_size), 1e7)
  # the legacy corpus encoding, which the fixture reproduces
  expect_equal(meta$ref_encoding, "json_varchar")
  expect_equal(as.numeric(meta$n_source_files), 1)
  expect_true(all(c("n_edges", "built_at", "builder_version") %in% names(meta)))
})

test_that("each partition is sorted by (cited_id, citing_id)", {
  # Not cosmetic: the fast lookup depends on row-group min/max, which only
  # hold if preserve_insertion_order was TRUE for the Stage 2 write. Getting
  # that wrong degrades every query to a scan with no visible error.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_citation_index(corpus_dir = corpus, verbose = FALSE)

  for (f in list.files(idx, pattern = "part-0\\.parquet$", recursive = TRUE,
                       full.names = TRUE)) {
    e <- as.data.frame(arrow::read_parquet(f))
    expect_false(is.unsorted(e$cited_id), label = paste("sorted:", basename(dirname(f))))
  }
})

test_that("block_size controls the partition count", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)

  fine <- build_citation_index(corpus_dir = corpus, block_size = 1e6,
                               verbose = FALSE)
  n_fine <- length(list.dirs(fine, recursive = FALSE))
  unlink(fine, recursive = TRUE)

  coarse <- build_citation_index(corpus_dir = corpus, block_size = 1e8,
                                 verbose = FALSE)
  n_coarse <- length(list.dirs(coarse, recursive = FALSE))

  expect_gt(n_fine, n_coarse)
})

test_that("build_citation_index() skips a complete index unless overwritten", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_citation_index(corpus_dir = corpus, verbose = FALSE)
  meta_before <- .oas_read_index_meta(idx)$built_at

  expect_message(build_citation_index(corpus_dir = corpus, verbose = FALSE),
                 "creation skipped")
  expect_equal(.oas_read_index_meta(idx)$built_at, meta_before)

  build_citation_index(corpus_dir = corpus, overwrite = TRUE, verbose = FALSE)
  expect_true(file.exists(file.path(idx, "_index_meta.parquet")))
})

test_that("an index without _index_meta.parquet is reported as incomplete", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_citation_index(corpus_dir = corpus, verbose = FALSE)
  unlink(file.path(idx, "_index_meta.parquet"))

  expect_error(
    .oas_require_index(idx, "citation", "build_citation_index"),
    class = "openalexSnapshot_incomplete_index"
  )
  # and it is still a missing-index condition, so callers can catch broadly
  expect_error(
    .oas_require_index(idx, "citation", "build_citation_index"),
    class = "openalexSnapshot_missing_index"
  )
})

test_that("a native VARCHAR[] referenced_works gives the same edges as JSON", {
  # The official OpenAlex parquet uses a real list column; the legacy converted
  # corpus uses a JSON string. Both must produce an identical index.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  json_idx <- build_citation_index(corpus_dir = corpus, verbose = FALSE)
  json_edges <- dplyr::collect(arrow::open_dataset(
    list.files(json_idx, pattern = "part-0\\.parquet$", recursive = TRUE,
               full.names = TRUE)))

  # rewrite the same corpus with a native list column
  tmp2 <- withr::local_tempdir()
  works2 <- file.path(tmp2, "parquet", "works", "updated_date=2020-01-01")
  dir.create(works2, recursive = TRUE)
  src <- as.data.frame(dplyr::collect(arrow::open_dataset(corpus)))
  src$referenced_works <- lapply(src$referenced_works, function(x) {
    if (is.na(x) || x == "[]") character(0) else unlist(regmatches(
      x, gregexpr("https://openalex\\.org/W[0-9]+", x)))
  })
  arrow::write_parquet(src, file.path(works2, "part_0000.parquet"))

  corpus2 <- file.path(tmp2, "parquet", "works")
  con <- .oas_con(); on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_equal(
    .oas_refs_expr(con, .oas_corpus_files(corpus2))$enc,
    "native_list"
  )

  list_idx <- build_citation_index(corpus_dir = corpus2, verbose = FALSE)
  list_edges <- dplyr::collect(arrow::open_dataset(
    list.files(list_idx, pattern = "part-0\\.parquet$", recursive = TRUE,
               full.names = TRUE)))

  expect_equal(nrow(json_edges), nrow(list_edges))
  expect_setequal(paste(json_edges$cited_id, json_edges$citing_id),
                  paste(list_edges$cited_id, list_edges$citing_id))
})

test_that("indexing a dataset without referenced_works fails clearly", {
  tmp <- withr::local_tempdir()
  d <- file.path(tmp, "parquet", "authors", "updated_date=2020-01-01")
  dir.create(d, recursive = TRUE)
  arrow::write_parquet(data.frame(id = "https://openalex.org/A1", x = 1),
                       file.path(d, "part_0000.parquet"))
  expect_error(
    build_citation_index(corpus_dir = file.path(tmp, "parquet", "authors"),
                         verbose = FALSE),
    "referenced_works"
  )
})


test_that("a parallel multi-batch build matches a sequential one", {
  # Regression: every worker must get its OWN DuckDB spill directory. Sharing
  # one temp_directory across concurrent DuckDB instances makes them write
  # colliding duckdb_temp_storage_*.tmp files, which fails mid-build with
  # "Could not read enough bytes from file". Only reproducible with >1 worker
  # AND >1 batch, hence batch_bytes = 1.
  skip_on_cran()
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)

  seq_idx <- build_citation_index(corpus_dir = corpus, verbose = FALSE)
  seq_edges <- dplyr::collect(arrow::open_dataset(
    list.files(seq_idx, pattern = "part-0\\.parquet$", recursive = TRUE,
               full.names = TRUE)))
  unlink(seq_idx, recursive = TRUE)

  par_idx <- build_citation_index(corpus_dir = corpus, workers = 4,
                                  batch_bytes = 1, verbose = FALSE)
  par_edges <- dplyr::collect(arrow::open_dataset(
    list.files(par_idx, pattern = "part-0\\.parquet$", recursive = TRUE,
               full.names = TRUE)))

  expect_equal(nrow(seq_edges), nrow(par_edges))
  expect_setequal(paste(seq_edges$cited_id, seq_edges$citing_id),
                  paste(par_edges$cited_id, par_edges$citing_id))
})


test_that("temp_dir defaults to local disk, not beside the index", {
  # Spilling onto the volume holding the corpus makes spill writes compete
  # with corpus reads; on an external USB SSD that measured 8.18 s/batch
  # against 0.76 s/batch. The default must not walk into that.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_citation_index(corpus_dir = corpus, verbose = FALSE)

  # nothing left beside the index on the corpus volume
  expect_false(dir.exists(paste0(idx, "_tmp")))
  expect_setequal(setdiff(list.files(dirname(idx)), "works"),
                  c("works_cite_idx"))
})

test_that("a build that cannot fit is refused before it starts", {
  tmp <- withr::local_tempdir()
  expect_error(
    .oas_check_space(tmp, need_bytes = 1e18, what = "citation index"),
    "Not enough space"
  )
  # unknown free space must not block
  expect_silent(.oas_check_space(tmp, need_bytes = 1))
})
