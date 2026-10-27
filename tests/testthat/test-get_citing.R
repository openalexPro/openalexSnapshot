# Tests for get_citing() / get_cited().

# Build a corpus plus all three indexes once per test that needs them.
setup_indexed <- function(env = parent.frame()) {
  tmp <- withr::local_tempdir(.local_envir = env)
  corpus <- make_tiny_corpus(tmp)
  build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)
  build_doi_index(corpus_dir = corpus, verbose = FALSE)
  build_citation_index(corpus_dir = corpus, verbose = FALSE)
  list(root = file.path(tmp, "parquet"), corpus = corpus)
}

test_that("get_citing() returns an edge list with A cites B orientation", {
  s <- setup_indexed()
  # W1000000 is referenced by several later works in the fixture
  e <- get_citing("W1000000", root_dir = s$root, verbose = FALSE)

  expect_s3_class(e, "data.frame")
  expect_equal(names(e), c("from", "to"))
  expect_gt(nrow(e), 0L)
  # every edge points AT the keypaper: the citers are `from`
  expect_true(all(e$to == "https://openalex.org/W1000000"))
  expect_true(all(grepl("^https://openalex\\.org/W", e$from)))
})

test_that("get_citing() agrees with a brute-force scan of the corpus", {
  s <- setup_indexed()
  src <- as.data.frame(dplyr::collect(arrow::open_dataset(s$corpus)))

  for (kp in c("W1000000", "W5000000", "W9000000")) {
    truth <- src$id[!is.na(src$referenced_works) &
                      grepl(paste0("/", kp, "\""), src$referenced_works)]
    got <- get_citing(kp, root_dir = s$root, return = "ids", verbose = FALSE)
    expect_setequal(got, truth)
  }
})

test_that("get_cited() returns exactly the keypaper's referenced_works", {
  s <- setup_indexed()
  src <- as.data.frame(dplyr::collect(arrow::open_dataset(s$corpus)))
  kp <- src$id[!is.na(src$referenced_works) & src$referenced_works != "[]"][1]
  expected <- unlist(regmatches(
    src$referenced_works[src$id == kp],
    gregexpr("https://openalex\\.org/W[0-9]+", src$referenced_works[src$id == kp])))

  e <- get_cited(kp, root_dir = s$root, verbose = FALSE)
  expect_true(all(e$from == kp))       # the keypaper is the citer
  expect_setequal(e$to, expected)
})

test_that("get_cited() handles NULL and empty referenced_works", {
  s <- setup_indexed()
  # fixture work 1 has NA refs, work 2 has "[]"
  expect_equal(nrow(get_cited("W1000000", root_dir = s$root, verbose = FALSE)), 0L)
  expect_equal(nrow(get_cited("W5000000", root_dir = s$root, verbose = FALSE)), 0L)
})

test_that("keypaper is vectorised and may mix ids and DOIs in one call", {
  s <- setup_indexed()
  mixed <- c("W9000000",                                # short id
             "https://openalex.org/W13000000",          # long id
             "10.1234/test.5",                          # bare DOI
             "https://doi.org/10.1234/test.6")          # DOI with resolver
  e <- get_cited(mixed, root_dir = s$root, verbose = FALSE)

  expect_gt(nrow(e), 0L)
  # every keypaper that has references contributes, and nothing else does
  expect_true(all(e$from %in% .oas_resolve_keypaper(mixed, root_dir = s$root,
                                                    verbose = FALSE)))
  expect_gt(length(unique(e$from)), 1L)
})

test_that("short and long form ids give identical results", {
  s <- setup_indexed()
  a <- get_citing("W1000000", root_dir = s$root, return = "ids", verbose = FALSE)
  b <- get_citing("https://openalex.org/W1000000", root_dir = s$root,
                  return = "ids", verbose = FALSE)
  expect_equal(sort(a), sort(b))
})

test_that("return = 'ids' and 'records' are consistent with 'edges'", {
  s <- setup_indexed()
  e   <- get_citing("W1000000", root_dir = s$root, verbose = FALSE)
  ids <- get_citing("W1000000", root_dir = s$root, return = "ids", verbose = FALSE)
  rec <- get_citing("W1000000", root_dir = s$root, return = "records",
                    columns = c("id", "title"), verbose = FALSE)

  expect_setequal(ids, unique(e$from))
  expect_equal(nrow(rec), length(ids))
  expect_equal(names(rec), c("id", "title"))
  expect_setequal(rec$id, ids)
})

test_that("an unknown keypaper yields an empty result, not an error", {
  s <- setup_indexed()
  e <- get_citing("W999999999", root_dir = s$root, verbose = FALSE)
  expect_equal(nrow(e), 0L)
  expect_equal(names(e), c("from", "to"))
  expect_equal(length(get_citing("W999999999", root_dir = s$root,
                                 return = "ids", verbose = FALSE)), 0L)
})

test_that("max_results guards the high-citation blow-up", {
  s <- setup_indexed()
  expect_error(
    get_citing("W1000000", root_dir = s$root, max_results = 1L, verbose = FALSE),
    "max_results"
  )
  expect_no_error(
    get_citing("W1000000", root_dir = s$root, max_results = Inf, verbose = FALSE)
  )
})

test_that("input validation is specific about what is wrong", {
  s <- setup_indexed()
  expect_error(get_citing("banana", root_dir = s$root, verbose = FALSE),
               "Not an OpenAlex ID or a DOI")
  expect_error(get_citing("A5023888391", root_dir = s$root, verbose = FALSE),
               "apply to works")
  expect_error(get_citing(character(0), root_dir = s$root, verbose = FALSE),
               "non-empty")
  expect_error(get_citing("W1000000", root_dir = s$root, depth = 2,
                          verbose = FALSE),
               "depth = 1")
})

test_that("an unresolvable DOI warns rather than failing silently", {
  s <- setup_indexed()
  expect_warning(
    .oas_resolve_keypaper(c("W1000000", "10.9999/nope"), root_dir = s$root,
                          verbose = FALSE),
    "could not be resolved"
  )
})

test_that("a missing citation index names the builder that creates it", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  expect_error(
    get_citing("W1000000", root_dir = file.path(tmp, "parquet"), verbose = FALSE),
    class = "openalexSnapshot_missing_citation_index"
  )
  expect_error(
    get_citing("W1000000", root_dir = file.path(tmp, "parquet"), verbose = FALSE),
    "build_citation_index"
  )
})

test_that("get_cited() needs no citation index", {
  # Asymmetry worth pinning: the cited direction is just referenced_works.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  expect_no_error(
    get_cited("W9000000", root_dir = file.path(tmp, "parquet"), verbose = FALSE)
  )
})

test_that("a stale index warns but still answers", {
  s <- setup_indexed()
  idx <- file.path(s$root, "works_cite_idx")
  meta <- .oas_read_index_meta(idx)
  meta$n_source_files <- 999L
  arrow::write_parquet(meta, file.path(idx, "_index_meta.parquet"))

  expect_warning(
    e <- get_citing("W1000000", root_dir = s$root, verbose = FALSE),
    "was built from 999 files"
  )
  expect_gt(nrow(e), 0L)   # a frozen snapshot must stay usable

  withr::local_options(openalexSnapshot.check_index_staleness = FALSE)
  expect_no_warning(get_citing("W1000000", root_dir = s$root, verbose = FALSE))
})

test_that("keypapers that are all unresolvable DOIs give an empty result", {
  s <- setup_indexed()
  expect_warning(
    e <- get_citing("10.9999/nope", root_dir = s$root, verbose = FALSE),
    "could not be resolved"
  )
  expect_equal(e, data.frame(from = character(0), to = character(0)))

  expect_warning(
    ids <- get_cited("10.9999/nope", root_dir = s$root, return = "ids",
                     verbose = FALSE),
    "could not be resolved"
  )
  expect_identical(ids, character(0))

  expect_warning(
    rec <- get_citing("10.9999/nope", root_dir = s$root, return = "records",
                      verbose = FALSE),
    "could not be resolved"
  )
  expect_equal(rec, data.frame())
})

test_that("a keypaper of only blanks and NAs is rejected", {
  expect_error(get_citing(c(NA, "", "  "), root_dir = "x", verbose = FALSE),
               "contains no usable values")
})

test_that("a keypaper whose cited_block has no partition yields no edges", {
  # W888888888 falls in cited_block=88; nothing in the fixture is cited there.
  s <- setup_indexed()
  expect_false(dir.exists(file.path(s$root, "works_cite_idx", "cited_block=88")))
  expect_equal(nrow(get_citing("W888888888", root_dir = s$root,
                               verbose = FALSE)), 0L)
  expect_identical(get_citing("W888888888", root_dir = s$root, return = "ids",
                              verbose = FALSE), character(0))
})

test_that("an uncited keypaper in an existing partition gives empty records", {
  # W5000000 sits in cited_block=0, which exists, but no work cites it.
  s <- setup_indexed()
  expect_true(dir.exists(file.path(s$root, "works_cite_idx", "cited_block=0")))
  rec <- get_citing("W5000000", root_dir = s$root, return = "records",
                    verbose = FALSE)
  expect_equal(rec, data.frame())
})

test_that("verbose = TRUE reports partitions read and records extracted", {
  s <- setup_indexed()
  msgs <- capture_messages(
    rec <- get_citing("W1000000", root_dir = s$root, return = "records",
                      columns = "id", verbose = TRUE)
  )
  expect_match(msgs, "^Reading 1 index partition\\(s\\) for 1 keypaper\\(s\\)",
               all = FALSE)
  expect_match(msgs, paste0("^Extracting ", nrow(rec), " record\\(s\\)"),
               all = FALSE)
})

test_that("get_cited() of a keypaper absent from the id index is empty", {
  s <- setup_indexed()
  expect_equal(nrow(get_cited("W2000000", root_dir = s$root, verbose = FALSE)),
               0L)
})

test_that("get_cited() reads a native VARCHAR[] referenced_works", {
  # The official parquet stores a list column, which needs no json extension.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  f <- file.path(corpus, "updated_date=2020-01-01", "part_0000.parquet")
  src <- as.data.frame(arrow::read_parquet(f, mmap = FALSE))
  json_refs <- src$referenced_works
  src$referenced_works <- lapply(json_refs, function(x) {
    if (is.na(x) || x == "[]") character(0) else unlist(regmatches(
      x, gregexpr("https://openalex\\.org/W[0-9]+", x)))
  })
  arrow::write_parquet(src, f)
  build_corpus_index(corpus_dir = corpus, verbose = FALSE)

  kp <- src$id[5]
  e <- get_cited(kp, root_dir = file.path(tmp, "parquet"), verbose = FALSE)
  expect_true(all(e$from == kp))
  expect_setequal(e$to, src$referenced_works[[5]])
})

test_that("staleness is not checked when the recorded corpus has moved", {
  # The corpus path in the metadata no longer exists (e.g. the volume was
  # remounted elsewhere); with nothing to compare against, stay quiet.
  s <- setup_indexed()
  idx <- file.path(s$root, "works_cite_idx")
  meta <- .oas_read_index_meta(idx)
  meta$n_source_files <- 999L
  meta$corpus_dir <- file.path(tempdir(), "no_such_corpus")
  arrow::write_parquet(meta, file.path(idx, "_index_meta.parquet"))

  expect_no_warning(
    e <- get_citing("W1000000", root_dir = s$root, verbose = FALSE)
  )
  expect_gt(nrow(e), 0L)
})
