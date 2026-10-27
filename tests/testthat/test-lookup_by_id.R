# Tests for lookup_by_id(): argument handling, root_dir mode, and the
# branches of the pure-R implementation not exercised by
# test-pure-r-backend.R. make_tiny_corpus() lives in helper.R.

# A corpus plus its id index. block_size = 1e7 puts the first three fixture
# works (W1000000, W5000000, W9000000) in id_block=0.
setup_id_index <- function(env = parent.frame()) {
  tmp <- withr::local_tempdir(.local_envir = env)
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, block_size = 1e7,
                            verbose = FALSE)
  list(tmp = tmp, corpus = corpus, idx = idx)
}

test_that("lookup_by_id() requires non-empty ids", {
  expect_error(lookup_by_id(index_file = "x"), "'ids' must be provided")
  expect_error(lookup_by_id(ids = character(0), index_file = "x"),
               "'ids' must be provided")
})

test_that("lookup_by_id() requires root_dir or index_file", {
  expect_error(lookup_by_id(ids = "W1"),
               "Provide either `root_dir` or `index_file`")
})

test_that("root_dir mode writes one extract per dataset into project_dir", {
  s <- setup_id_index()
  proj <- file.path(s$tmp, "project")

  res <- lookup_by_id(root_dir = s$tmp, ids = tiny_ids()[1:3],
                      project_dir = proj, data_sets = "works",
                      verbose = FALSE)
  expect_equal(res, proj)
  out <- file.path(proj, "snapshot_extract_works")
  expect_true(dir.exists(out))
  got <- dplyr::collect(arrow::open_dataset(out))
  expect_setequal(got$id, .oas_normalize_id(tiny_ids()[1:3]))
})

test_that("root_dir mode skips datasets that have no index", {
  s <- setup_id_index()
  proj <- file.path(s$tmp, "project")

  msgs <- capture_messages(
    lookup_by_id(root_dir = s$tmp, ids = tiny_ids()[1],
                 project_dir = proj, data_sets = c("authors", "works"),
                 verbose = TRUE)
  )
  expect_match(msgs, "No index for dataset 'authors', skipping.",
               fixed = TRUE, all = FALSE)
  expect_equal(list.files(proj), "snapshot_extract_works")
})

test_that("root_dir mode requires project_dir", {
  s <- setup_id_index()
  expect_error(
    lookup_by_id(root_dir = s$tmp, ids = tiny_ids()[1], data_sets = "works",
                 verbose = FALSE),
    "project_dir must be provided in root_dir mode"
  )
})

test_that("root_dir mode errors when no index has been built", {
  tmp <- withr::local_tempdir()
  make_tiny_corpus(tmp)
  expect_error(
    lookup_by_id(root_dir = tmp, ids = tiny_ids()[1],
                 project_dir = file.path(tmp, "project"), verbose = FALSE),
    "No index files found under .*Run build_corpus_index\\(\\) first"
  )
})

test_that("root_dir mode with data_sets = NULL discovers built indexes", {
  s <- setup_id_index()
  proj <- file.path(s$tmp, "project")

  lookup_by_id(root_dir = s$tmp, ids = tiny_ids()[1:2], project_dir = proj,
               verbose = FALSE)
  expect_equal(list.files(proj), "snapshot_extract_works")
})

test_that("an existing output directory is refused rather than overwritten", {
  s <- setup_id_index()
  out <- file.path(s$tmp, "extract")
  dir.create(out)
  expect_error(
    lookup_by_id(ids = tiny_ids()[1], index_file = s$idx, output = out,
                 verbose = FALSE),
    "Output directory already exists"
  )
})

test_that("ids absent from an existing block give an empty result", {
  # W2000000 falls in id_block=0, which exists, but is not in the corpus: the
  # partition is read and filtered, not short-circuited.
  s <- setup_id_index()
  expect_true(dir.exists(file.path(s$idx, "id_block=0")))

  msgs <- capture_messages(
    got <- lookup_by_id(ids = "W2000000", index_file = s$idx, verbose = TRUE)
  )
  expect_match(msgs, "^No matching records found in index", all = FALSE)
  expect_equal(nrow(got), 0L)

  # with output, nothing is written and output is returned invisibly
  out <- file.path(s$tmp, "extract")
  expect_invisible(
    res <- lookup_by_id(ids = "W2000000", index_file = s$idx, output = out,
                        verbose = FALSE)
  )
  expect_equal(res, out)
  expect_false(dir.exists(out))
})

test_that("ids in no indexed block return output unchanged in output mode", {
  s <- setup_id_index()
  out <- file.path(s$tmp, "extract")
  res <- lookup_by_id(ids = "W999999999", index_file = s$idx, output = out,
                      verbose = FALSE)
  expect_equal(res, out)
  expect_false(dir.exists(out))
})

test_that("verbose = TRUE reports each step of an in-memory lookup", {
  s <- setup_id_index()
  msgs <- capture_messages(
    got <- lookup_by_id(ids = c(tiny_ids()[1:2], "W2000000"),
                        index_file = s$idx, verbose = TRUE)
  )
  expect_equal(nrow(got), 2L)
  expect_match(msgs, "^Looking up 3 ids", all = FALSE)
  expect_match(msgs, "^Found 2 matching records in index", all = FALSE)
  expect_match(msgs, "^Reading from 1 parquet file", all = FALSE)
  expect_match(msgs, "^Retrieved 2 records", all = FALSE)
})

test_that("verbose = TRUE reports the record count written to output", {
  s <- setup_id_index()
  out <- file.path(s$tmp, "extract")
  msgs <- capture_messages(
    lookup_by_id(ids = tiny_ids()[1:3], index_file = s$idx, output = out,
                 verbose = TRUE)
  )
  expect_match(msgs, "^Written 3 records to", all = FALSE)
})

test_that("verbose = TRUE reports duplicate index entries being dropped", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  # the same file under a second updated_date= partition duplicates every id
  newer <- file.path(corpus, "updated_date=2021-01-01")
  dir.create(newer)
  file.copy(file.path(corpus, "updated_date=2020-01-01", "part_0000.parquet"),
            newer)
  idx <- build_corpus_index(corpus_dir = corpus, verbose = FALSE)

  msgs <- capture_messages(
    got <- lookup_by_id(ids = tiny_ids()[1:2], index_file = idx,
                        verbose = TRUE)
  )
  expect_match(msgs, "^Dropping 2 duplicate index entries \\(kept latest\\)",
               all = FALSE)
  expect_equal(nrow(got), 2L)
})

test_that("add_columns must be a named list", {
  s <- setup_id_index()
  expect_error(
    lookup_by_id(ids = tiny_ids()[1], index_file = s$idx,
                 add_columns = list("keypaper"), verbose = FALSE),
    "`add_columns` must be a named list"
  )
  expect_error(
    lookup_by_id(ids = tiny_ids()[1], index_file = s$idx,
                 add_columns = list(relation = "a", "b"), verbose = FALSE),
    "`add_columns` must be a named list"
  )
})

test_that("a source file that cannot be read is an error naming the file", {
  # Not a warning: an extract missing whole source files is not a result.
  s <- setup_id_index()
  expect_error(
    suppressWarnings(
      lookup_by_id(ids = tiny_ids()[1], index_file = s$idx,
                   columns = "no_such_column", verbose = FALSE)
    ),
    "Failed to read from .*part_0000\\.parquet"
  )
})

test_that("file_row_number never leaks, even when requested as a column", {
  s <- setup_id_index()
  got <- lookup_by_id(ids = tiny_ids()[1:2], index_file = s$idx,
                      columns = c("id", "file_row_number"), verbose = FALSE)
  expect_equal(names(got), "id")
  expect_equal(nrow(got), 2L)
})

test_that("selected is a column selection, as documented", {
  skip("Known bug: `selected` is documented as a column selection but is used as an output path for the index matches")
  s <- setup_id_index()
  got <- lookup_by_id(ids = tiny_ids()[1:2], index_file = s$idx,
                      selected = c("id", "title"), verbose = FALSE)
  expect_equal(names(got), c("id", "title"))
})
