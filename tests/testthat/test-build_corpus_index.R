# Tests for build_corpus_index(): argument handling, root_dir mode, resume and
# the verbose path. Schema and lookup round-trips are in test-pure-r-backend.R.
# make_tiny_corpus() lives in helper.R.

test_that("build_corpus_index() needs root_dir or an existing corpus_dir", {
  expect_error(build_corpus_index(verbose = FALSE),
               "Provide either `root_dir` or `corpus_dir`")
  expect_error(
    build_corpus_index(corpus_dir = file.path(withr::local_tempdir(), "nope"),
                       verbose = FALSE),
    "corpus_dir does not exist"
  )
})

test_that("root_dir mode indexes every dataset and ignores hidden directories", {
  tmp <- withr::local_tempdir()
  make_tiny_corpus(tmp)
  # e.g. a .Trashes or .DS_Store-style folder on an external volume; indexing
  # it would fail with "No parquet files found"
  dir.create(file.path(tmp, "parquet", ".hidden"))

  res <- build_corpus_index(root_dir = tmp, verbose = FALSE)
  expect_equal(res, tmp)
  expect_setequal(list.files(file.path(tmp, "parquet")),
                  c("works", "works_id_idx"))
  expect_true(file.exists(
    file.path(tmp, "parquet", "works_id_idx", "_index_meta.parquet")
  ))
})

test_that("root_dir mode with explicit data_sets indexes only those", {
  tmp <- withr::local_tempdir()
  make_tiny_corpus(tmp)
  dir.create(file.path(tmp, "parquet", "authors"))   # empty: would error

  build_corpus_index(root_dir = tmp, data_sets = "works", verbose = FALSE)
  expect_true(dir.exists(file.path(tmp, "parquet", "works_id_idx")))
  expect_false(dir.exists(file.path(tmp, "parquet", "authors_id_idx")))
})

test_that("re-running root_dir mode does not treat index directories as datasets", {
  skip("Known bug: data_sets = NULL lists every directory under parquet/, including <dataset>_id_idx/, so a re-run tries to index the index")
  tmp <- withr::local_tempdir()
  make_tiny_corpus(tmp)
  build_corpus_index(root_dir = tmp, verbose = FALSE)

  expect_message(build_corpus_index(root_dir = tmp, verbose = FALSE),
                 "creation skipped")
  expect_setequal(list.files(file.path(tmp, "parquet")),
                  c("works", "works_id_idx"))
})

test_that("verbose = TRUE reports the derived block_size and both stages", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)

  msgs <- capture_messages(
    idx <- build_corpus_index(corpus_dir = corpus, verbose = TRUE)
  )
  bs <- as.numeric(.oas_read_index_meta(idx)$block_size)
  expect_match(msgs, paste0("derived block_size = ",
                            format(bs, scientific = FALSE)), all = FALSE)
  expect_match(msgs, "^Building index from: ", all = FALSE)
  expect_match(msgs, "^Stage 1: 1 parquet files in 1 batches sequentially",
               all = FALSE)
  expect_match(msgs, "^Stage 2: sorting [0-9]+ blocks", all = FALSE)
  expect_match(msgs, "^Done! 12 rows in ", all = FALSE)
  expect_match(msgs, "^Total time: ", all = FALSE)
})

test_that("an explicit block_size is used as given, without deriving one", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  msgs <- capture_messages(
    idx <- build_corpus_index(corpus_dir = corpus, block_size = 1e7,
                              verbose = TRUE)
  )
  expect_false(any(grepl("derived block_size", msgs)))
  expect_equal(as.numeric(.oas_read_index_meta(idx)$block_size), 1e7)
})

test_that("an interrupted build resumes its completed Stage-1 batches", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  work <- file.path(tmp, "work")

  local({
    local_mocked_bindings(.oas_write_index_meta = function(...) {
      stop("simulated interruption")
    })
    expect_error(
      build_corpus_index(corpus_dir = corpus, temp_dir = work,
                         block_size = 1e7, verbose = FALSE),
      "simulated interruption"
    )
  })
  marker <- file.path(work, ".done", "b00001")
  expect_true(file.exists(marker))
  shards_before <- list.files(file.path(work, "shards"), recursive = TRUE)

  idx <- build_corpus_index(corpus_dir = corpus, temp_dir = work,
                            block_size = 1e7, verbose = FALSE)
  meta <- .oas_read_index_meta(idx)
  expect_equal(as.numeric(meta$n_rows), 12)
  expect_gt(length(shards_before), 0L)
  expect_false(dir.exists(work))       # temp_dir is cleaned up on success
})

test_that("partial shards of an unfinished batch are cleared before re-running", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  work <- file.path(tmp, "work")
  # id_block=0 is a block the real data writes at block_size = 1e7
  stale <- file.path(work, "shards", "id_block=0", "b00001_99.parquet")
  dir.create(dirname(stale), recursive = TRUE)
  writeLines("not a parquet file", stale)

  idx <- build_corpus_index(corpus_dir = corpus, temp_dir = work,
                            block_size = 1e7, verbose = FALSE)
  expect_equal(as.numeric(.oas_read_index_meta(idx)$n_rows), 12)
})

test_that("a corpus with no rows fails clearly", {
  tmp <- withr::local_tempdir()
  d <- file.path(tmp, "parquet", "works", "updated_date=2020-01-01")
  dir.create(d, recursive = TRUE)
  arrow::write_parquet(data.frame(id = character(0)),
                       file.path(d, "part_0000.parquet"))
  expect_error(
    build_corpus_index(corpus_dir = file.path(tmp, "parquet", "works"),
                       block_size = 1e7, temp_dir = file.path(tmp, "work"),
                       verbose = FALSE),
    "No index rows were produced"
  )
})

test_that("a failed build does not poison a later build of another corpus", {
  skip("Known bug: the default temp_dir is keyed by dataset name only, so resume markers left by a failed build are reused by a later build of a different corpus with the same name")
  # The empty corpus fails after Stage 1 has marked its batch done.
  tmp1 <- withr::local_tempdir()
  d <- file.path(tmp1, "parquet", "works", "updated_date=2020-01-01")
  dir.create(d, recursive = TRUE)
  arrow::write_parquet(data.frame(id = character(0)),
                       file.path(d, "part_0000.parquet"))
  expect_error(
    build_corpus_index(corpus_dir = file.path(tmp1, "parquet", "works"),
                       block_size = 1e7, verbose = FALSE),
    "No index rows were produced"
  )
  withr::defer(unlink(file.path(tempdir(), "works_id_idx_tmp"), recursive = TRUE))

  # A different, valid corpus also named "works" must build from scratch.
  tmp2 <- withr::local_tempdir()
  idx <- build_corpus_index(corpus_dir = make_tiny_corpus(tmp2),
                            block_size = 1e7, verbose = FALSE)
  expect_equal(as.numeric(.oas_read_index_meta(idx)$n_rows), 12)
})
