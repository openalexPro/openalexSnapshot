# Tests for the shared internal helpers in utils_duckdb.R.

test_that(".oas_con() applies memory_limit and threads", {
  con <- .oas_con(memory_limit = "1GiB", threads = 1L)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  got <- DBI::dbGetQuery(con, paste(
    "SELECT current_setting('memory_limit') AS m,",
    "current_setting('threads') AS t"
  ))
  expect_equal(got$m, "1.0 GiB")
  expect_equal(as.integer(got$t), 1L)
})

test_that(".oas_parquet_root() requires a path", {
  expect_error(.oas_parquet_root(NULL), "snapshot path is required")
})

test_that(".oas_corpus_files() lists parquet files sorted, and errors on none", {
  tmp <- withr::local_tempdir()
  expect_error(.oas_corpus_files(tmp), "No parquet files found under")

  dir.create(file.path(tmp, "b"))
  dir.create(file.path(tmp, "a"))
  arrow::write_parquet(data.frame(x = 1), file.path(tmp, "b", "p.parquet"))
  arrow::write_parquet(data.frame(x = 1), file.path(tmp, "a", "p.parquet"))
  writeLines("not parquet", file.path(tmp, "a", "notes.txt"))

  got <- .oas_corpus_files(tmp)
  expect_equal(basename(dirname(got)), c("a", "b"))
  expect_true(all(grepl("\\.parquet$", got)))
})

test_that(".oas_derive_block_size() falls back to 1e7 for a zero id span", {
  # A dataset holding a single id (or ids that all parse to the same number)
  # has no range to divide; the fallback must be a usable width, not 0 or Inf.
  tmp <- withr::local_tempdir()
  f <- file.path(tmp, "part_0000.parquet")
  arrow::write_parquet(data.frame(id = "https://openalex.org/W42"), f)
  expect_equal(.oas_derive_block_size(f), 1e7)
})

test_that(".oas_free_bytes() returns NA when df is unavailable", {
  # Callers treat NA as "unknown"; it must not be an error or a guess.
  tmp <- withr::local_tempdir()
  expect_true(is.numeric(.oas_free_bytes(tmp)))
  withr::local_envvar(PATH = "")
  expect_identical(.oas_free_bytes(tmp), NA_real_)
})

test_that(".oas_check_space() does not block when free space is unknown", {
  local_mocked_bindings(.oas_free_bytes = function(path) NA_real_)
  expect_silent(
    expect_null(.oas_check_space(withr::local_tempdir(), need_bytes = 1e18))
  )
})

test_that(".oas_check_space() warns when space is tight but sufficient", {
  local_mocked_bindings(.oas_free_bytes = function(path) 100 * 1024^3)
  tmp <- withr::local_tempdir()
  # enough, but not 1.5x headroom
  expect_warning(
    .oas_check_space(tmp, need_bytes = 80 * 1024^3, what = "DOI index"),
    "Only 100.0 GB free .* for the DOI index \\(estimated need 80.0 GB\\)"
  )
  # ample headroom: silent
  expect_silent(.oas_check_space(tmp, need_bytes = 10 * 1024^3))
})

test_that(".oas_ensure_json() fails with an actionable message", {
  # Simulate an unloadable extension with a connection that cannot run
  # anything: the error must say what is needed and how to get it.
  con <- .oas_con()
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_error(.oas_ensure_json(con), "needs DuckDB's `json` extension")
  expect_error(.oas_ensure_json(con), "INSTALL json", fixed = TRUE)
})

test_that(".oas_refs_expr() rejects an unsupported referenced_works type", {
  tmp <- withr::local_tempdir()
  f <- file.path(tmp, "part_0000.parquet")
  arrow::write_parquet(
    data.frame(id = "https://openalex.org/W1", referenced_works = 1L), f
  )
  con <- .oas_con()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_error(.oas_refs_expr(con, f),
               "Unsupported referenced_works column type: INTEGER")
})

test_that(".oas_refs_expr() refuses a corpus with mixed encodings", {
  # A partially refreshed corpus can hold both the legacy JSON text and the
  # official native list; one expression cannot unnest both.
  tmp <- withr::local_tempdir()
  json_f <- file.path(tmp, "a.parquet")
  list_f <- file.path(tmp, "b.parquet")
  arrow::write_parquet(
    data.frame(id = "https://openalex.org/W1",
               referenced_works = '["https://openalex.org/W2"]'),
    json_f
  )
  native <- data.frame(id = "https://openalex.org/W3")
  native$referenced_works <- list("https://openalex.org/W2")
  arrow::write_parquet(native, list_f)

  con <- .oas_con()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_error(.oas_refs_expr(con, c(json_f, list_f)),
               "encoded inconsistently .*json_varchar and native_list")
})

test_that(".oas_read_index_meta() returns NULL when there is no sidecar", {
  expect_null(.oas_read_index_meta(withr::local_tempdir()))
})
