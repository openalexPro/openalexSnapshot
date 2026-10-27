# Tests for the DOI index and DOI resolution.

test_that("build_doi_index() mirrors the _id_idx schema plus the DOI", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)

  idx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)
  expect_true(file.exists(idx))
  expect_match(idx, "works_doi_idx\\.parquet$")

  d <- as.data.frame(arrow::read_parquet(idx))
  expect_equal(names(d),
               c("doi", "id", "id_block", "parquet_file", "file_row_number"))
  expect_equal(d$id_block, .oas_id_block(d$id))
  expect_equal(unique(d$parquet_file),
               "works/updated_date=2020-01-01/part_0000.parquet")
})

test_that("the index is sorted by doi and carries no resolver prefix", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)

  d <- as.data.frame(arrow::read_parquet(idx))
  expect_false(is.unsorted(d$doi))
  expect_false(any(grepl("^https?://", d$doi)))
  expect_true(all(grepl("^10\\.", d$doi)))
})

test_that("works without a DOI are absent from the index", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)

  src <- dplyr::collect(arrow::open_dataset(corpus))
  d <- as.data.frame(arrow::read_parquet(idx))
  expect_equal(nrow(d), sum(!is.na(src$doi)))
  expect_false(any(is.na(d$doi)))
})

test_that("the SQL and R DOI normalisers agree on every indexed DOI", {
  # The write side normalises in SQL and the query side in R. If they ever
  # drift, every lookup silently misses. This is the guard.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)

  src <- as.data.frame(dplyr::collect(arrow::open_dataset(corpus)))
  src <- src[!is.na(src$doi), c("id", "doi")]
  d <- as.data.frame(arrow::read_parquet(idx))

  m <- merge(
    data.frame(id = src$id, r_key = .oas_normalize_doi(src$doi),
               stringsAsFactors = FALSE),
    d[, c("id", "doi")], by = "id"
  )
  expect_equal(nrow(m), nrow(src))
  expect_equal(m$r_key, m$doi)
})

test_that("a SICI DOI containing < > [ ] resolves", {
  # Regression anchor. openalexPro::extract_doi() used to truncate these, which
  # is why the index key uses .oas_normalize_doi() instead.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)

  sici <- c("10.1175/1520-0450(1963)002<0713:ooasds>2.0.co;2",
            "10.1577/1548-8659(1973)35[142:amosss]2.0.co;2")
  d <- as.data.frame(arrow::read_parquet(idx))
  expect_true(all(sici %in% d$doi))

  res <- doi_to_id(sici, index_file = idx, verbose = FALSE)
  expect_false(anyNA(res$id))
  expect_equal(res$doi, sici)
})

test_that("doi_to_id() accepts every resolver form", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)
  bare <- "10.1234/test.1"

  forms <- c(bare,
             paste0("https://doi.org/", bare),
             paste0("http://dx.doi.org/", bare),
             paste0("doi:", bare),
             paste0("DOI: ", toupper(bare)))
  res <- doi_to_id(forms, index_file = idx, verbose = FALSE)

  expect_equal(nrow(res), length(forms))
  expect_equal(res$doi_input, forms)      # input preserved verbatim
  expect_equal(unique(res$doi), bare)     # all normalise to one key
  expect_equal(length(unique(res$id)), 1L)
  expect_false(anyNA(res$id))
})

test_that("doi_to_id() reports unresolved DOIs as NA, in input order", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)

  res <- doi_to_id(c("10.1234/test.1", "10.9999/nope", "10.1234/test.2"),
                   index_file = idx, verbose = FALSE)
  expect_equal(nrow(res), 3L)
  expect_false(is.na(res$id[1]))
  expect_true(is.na(res$id[2]))
  expect_false(is.na(res$id[3]))
})

test_that("a missing DOI index raises a typed condition", {
  tmp <- withr::local_tempdir()
  expect_error(
    doi_to_id("10.1/x", index_file = file.path(tmp, "absent_doi_idx.parquet"),
              verbose = FALSE),
    class = "openalexSnapshot_missing_doi_index"
  )
})

test_that("lookup_by_doi() returns records and warns on unresolved input", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  didx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)
  build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)
  pq <- file.path(tmp, "parquet")

  got <- lookup_by_doi("10.1234/test.1", root_dir = pq, columns = c("id", "doi"),
                       verbose = FALSE)
  expect_equal(nrow(got), 1L)
  expect_equal(names(got), c("id", "doi"))

  expect_warning(
    lookup_by_doi(c("10.1234/test.1", "10.9999/nope"), root_dir = pq,
                  columns = "id", verbose = FALSE),
    "could not be resolved"
  )
})

test_that("build_doi_index() needs root_dir or an existing corpus_dir", {
  expect_error(build_doi_index(verbose = FALSE),
               "Provide either `root_dir` or `corpus_dir`")
  expect_error(
    build_doi_index(corpus_dir = file.path(withr::local_tempdir(), "nope"),
                    verbose = FALSE),
    "corpus_dir does not exist"
  )
})

test_that("root_dir mode builds the DOI index and returns root_dir", {
  tmp <- withr::local_tempdir()
  make_tiny_corpus(tmp)

  res <- build_doi_index(root_dir = tmp, verbose = FALSE)
  expect_equal(res, tmp)
  expect_true(file.exists(file.path(tmp, "parquet", "works_doi_idx.parquet")))
})

test_that("build_doi_index() skips an existing index unless overwritten", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)
  # mark the file so a rebuild is detectable
  arrow::write_parquet(data.frame(doi = "sentinel"), idx)

  expect_message(build_doi_index(corpus_dir = corpus, verbose = FALSE),
                 "index_file exists - creation skipped")
  expect_equal(as.data.frame(arrow::read_parquet(idx))$doi, "sentinel")

  build_doi_index(corpus_dir = corpus, overwrite = TRUE, verbose = FALSE)
  d <- as.data.frame(arrow::read_parquet(idx))
  expect_false("sentinel" %in% d$doi)
  expect_equal(nrow(d), 11L)            # every fixture work but the DOI-less one
})

test_that("a dataset without a doi column is refused", {
  tmp <- withr::local_tempdir()
  d <- file.path(tmp, "parquet", "authors", "updated_date=2020-01-01")
  dir.create(d, recursive = TRUE)
  arrow::write_parquet(data.frame(id = "https://openalex.org/A1"),
                       file.path(d, "part_0000.parquet"))
  expect_error(
    build_doi_index(corpus_dir = file.path(tmp, "parquet", "authors"),
                    verbose = FALSE),
    "Dataset 'authors' has no `doi` column"
  )
})

test_that("verbose = TRUE reports both stages", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  msgs <- capture_messages(build_doi_index(corpus_dir = corpus, verbose = TRUE))
  expect_match(msgs, "^Building DOI index from: ", all = FALSE)
  expect_match(msgs, "^Stage 1: 1 files in 1 batches", all = FALSE)
  expect_match(msgs, "^Stage 2: sorting by doi into ", all = FALSE)
  expect_match(msgs, "^Done! Index size: ", all = FALSE)
  expect_match(msgs, "^Total time: ", all = FALSE)
})

test_that("an existing Stage-1 shard is resumed rather than rebuilt", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  work <- file.path(tmp, "work")
  dir.create(work)
  # A shard left by an interrupted run. Resume trusts it, so the index must
  # consist of exactly its rows.
  arrow::write_parquet(
    data.frame(doi = "10.9999/planted", id = "https://openalex.org/W7",
               id_block = 0L, parquet_file = "works/x.parquet",
               file_row_number = 0),
    file.path(work, "doi_00001.parquet")
  )

  idx <- build_doi_index(corpus_dir = corpus, temp_dir = work, verbose = FALSE)
  d <- as.data.frame(arrow::read_parquet(idx))
  expect_equal(d$doi, "10.9999/planted")
  expect_false(dir.exists(work))       # temp_dir is cleaned up on success
})

test_that("doi_to_id() validates its arguments", {
  expect_error(doi_to_id(index_file = "x"), "`doi` must be provided")
  expect_error(doi_to_id(character(0), index_file = "x"),
               "`doi` must be provided")
  expect_error(doi_to_id("10.1/x"), "Provide either `root_dir` or `index_file`")
})

test_that("doi_to_id() reports the number of distinct DOIs it resolves", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_doi_index(corpus_dir = corpus, verbose = FALSE)
  expect_message(
    doi_to_id(c("10.1234/test.1", "https://doi.org/10.1234/test.1",
                "10.1234/test.2"), index_file = idx, verbose = TRUE),
    "Resolving 2 DOI\\(s\\)"
  )
})

test_that("lookup_by_doi() returns an empty frame when nothing resolves", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  build_doi_index(corpus_dir = corpus, verbose = FALSE)

  expect_warning(
    got <- lookup_by_doi("10.9999/nope", root_dir = tmp, verbose = FALSE),
    "1 DOI\\(s\\) could not be resolved.*10.9999/nope"
  )
  expect_s3_class(got, "data.frame")
  expect_equal(nrow(got), 0L)
})
