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
