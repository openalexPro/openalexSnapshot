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
