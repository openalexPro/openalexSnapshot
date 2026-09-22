# Tests for the pure-R/DuckDB backend.
#
# These need a real parquet corpus, so they build a tiny one in tempdir()
# rather than mocking. That is deliberate: the whole point of the pure-R
# backend is that it can be exercised without a compiled library, so these
# tests must not skip on a machine that has no Rust toolchain.

test_that(".oas_parquet_root accepts a root_dir, a parquet dir, or neither", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  expect_equal(.oas_parquet_root(tmp), normalizePath(file.path(tmp, "parquet")))
  expect_equal(.oas_parquet_root(file.path(tmp, "parquet")),
               normalizePath(file.path(tmp, "parquet")))
  # non-existent paths derive without erroring (path derivation != validation)
  expect_equal(.oas_parquet_root("/vol"), file.path("/vol", "parquet"))
  expect_error(.oas_parquet_root("/vol", must_exist = TRUE), "does not exist")
})

test_that("build_corpus_index(backend = 'r') produces the documented schema", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)

  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)
  expect_true(dir.exists(idx))
  expect_match(idx, "works_id_idx$")
  expect_true(file.exists(file.path(idx, "_index_meta.parquet")))

  parts <- list.files(idx, pattern = "part-0\\.parquet$", recursive = TRUE,
                      full.names = TRUE)
  expect_true(all(grepl("id_block=[0-9]+", parts)))
  got <- as.data.frame(dplyr::collect(arrow::open_dataset(parts)))
  expect_equal(sort(names(got)), c("file_row_number", "id", "parquet_file"))
  expect_equal(nrow(got), 12L)

  # id is long form; parquet_file is relative to the parquet root and includes
  # the dataset name; file_row_number is 0-indexed
  expect_true(all(grepl("^https://openalex\\.org/W", got$id)))
  expect_equal(unique(got$parquet_file),
               "works/updated_date=2020-01-01/part_0000.parquet")
  expect_equal(sort(got$file_row_number), 0:11)

})

test_that("build_corpus_index(backend = 'r') respects overwrite", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)
  before <- .oas_read_index_meta(idx)$built_at

  expect_message(
    build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE),
    "creation skipped"
  )
  expect_equal(.oas_read_index_meta(idx)$built_at, before)

  build_corpus_index(corpus_dir = corpus, backend = "r", overwrite = TRUE,
                     verbose = FALSE)
  expect_true(file.exists(idx))
})

test_that("lookup_by_id(backend = 'r') round-trips records", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)
  ids <- tiny_ids()[1:3]

  got <- lookup_by_id(ids = ids, index_file = idx, backend = "r", verbose = FALSE)
  expect_equal(nrow(got), 3L)
  expect_setequal(got$id, .oas_normalize_id(ids))
  # file_row_number is an index artefact and must not leak into the result
  expect_false("file_row_number" %in% names(got))
})

test_that("lookup_by_id(backend = 'r') accepts short and long form ids alike", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  short <- lookup_by_id(ids = tiny_ids()[1], index_file = idx, backend = "r",
                        verbose = FALSE)
  long  <- lookup_by_id(ids = paste0("https://openalex.org/", tiny_ids()[1]),
                        index_file = idx, backend = "r", verbose = FALSE)
  expect_equal(short$id, long$id)
})

test_that("lookup_by_id(backend = 'r') projects columns", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  got <- lookup_by_id(ids = tiny_ids()[5], index_file = idx, backend = "r",
                      columns = c("id", "referenced_works"), verbose = FALSE)
  expect_equal(names(got), c("id", "referenced_works"))
})

test_that("lookup_by_id(backend = 'r') injects add_columns as SQL literals", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  got <- lookup_by_id(
    ids = tiny_ids()[1:2], index_file = idx, backend = "r",
    columns = "id",
    add_columns = list(oa_input = "TRUE", relation = "keypaper"),
    verbose = FALSE
  )
  expect_equal(names(got), c("id", "oa_input", "relation"))
  # Values arrive as VARCHAR, matching openalexPro::pro_request_parquet(); the
  # cast to BOOLEAN happens at node assembly. This is a contract, not an
  # accident - openalexSnowball shares one assembly step across both paths.
  expect_type(got$oa_input, "character")
  expect_equal(unique(got$oa_input), "TRUE")
  expect_equal(unique(got$relation), "keypaper")
})

test_that("lookup_by_id(backend = 'r') writes parquet when output is given", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)
  out <- file.path(tmp, "extract")

  res <- lookup_by_id(ids = tiny_ids()[1:2], index_file = idx,
                      backend = "r", output = out, verbose = FALSE)
  expect_equal(res, out)
  expect_gt(length(list.files(out, pattern = "\\.parquet$")), 0L)
  expect_equal(nrow(dplyr::collect(arrow::open_dataset(out))), 2L)
})

test_that("lookup_by_id(backend = 'r') reports no matches without erroring", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  expect_message(
    got <- lookup_by_id(ids = "W999999999", index_file = idx, backend = "r",
                        verbose = TRUE),
    "No matching records"
  )
  expect_equal(nrow(got), 0L)

  # verbose = FALSE really is silent
  expect_silent(
    lookup_by_id(ids = "W999999999", index_file = idx, backend = "r",
                 verbose = FALSE)
  )
})

test_that("a missing index raises a typed condition naming its builder", {
  tmp <- withr::local_tempdir()
  expect_error(
    lookup_by_id(ids = "W1", index_file = file.path(tmp, "absent_id_idx"),
                 backend = "r", verbose = FALSE),
    class = "openalexSnapshot_missing_id_index"
  )
  expect_error(
    lookup_by_id(ids = "W1", index_file = file.path(tmp, "absent_id_idx"),
                 backend = "r", verbose = FALSE),
    class = "openalexSnapshot_missing_index"
  )
})

test_that("each id-index partition is sorted by id", {
  # Not cosmetic: this is the basis of pruning row groups rather than scanning.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  for (f in list.files(idx, pattern = "part-0\\.parquet$", recursive = TRUE,
                       full.names = TRUE)) {
    e <- as.data.frame(arrow::read_parquet(f))
    expect_false(is.unsorted(e$id), label = basename(dirname(f)))
  }
})

test_that("the id index spans several blocks and records block_size", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  blocks <- grep("^id_block=", list.dirs(idx, recursive = FALSE,
                                         full.names = FALSE), value = TRUE)
  expect_gt(length(blocks), 1L)   # fixture ids are spread deliberately
  meta <- .oas_read_index_meta(idx)
  expect_equal(meta$index_type, "id")
  expect_gte(as.numeric(meta$block_size), 1e4)      # derived, floored at 1e4
  expect_equal(as.numeric(meta$n_rows), 12)
  # the recorded width must be the one the blocks were actually cut with
  nums <- .oas_id_numeric(paste0("W", sub(".*/W", "", tiny_ids())))
  expect_setequal(
    sort(unique(floor(nums / as.numeric(meta$block_size)))),
    sort(as.numeric(sub("id_block=", "", blocks)))
  )
})

test_that("lookup_by_id() filters on id_block as well as id", {
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  # ids drawn from several different blocks must all still resolve
  ids <- tiny_ids()[c(1, 5, 9, 12)]
  got <- lookup_by_id(ids = ids, index_file = idx, backend = "r",
                      columns = "id", verbose = FALSE)
  expect_setequal(got$id, .oas_normalize_id(ids))
})



test_that("backend resolves to r, and the removed rust backend errors clearly", {
  expect_equal(.oas_backend("auto"), "r")
  expect_equal(.oas_backend("r"), "r")
  # An explanatory error, not an opaque "unused argument": existing code may
  # still pass backend = "rust".
  expect_error(.oas_backend("rust"), "removed in openalexSnapshot 0.1.0")
  expect_error(build_corpus_index(corpus_dir = ".", backend = "rust"),
               "removed in openalexSnapshot")
})

test_that("the package ships no compiled code", {
  expect_false(dir.exists(system.file("libs", package = "openalexSnapshot")) &&
                 length(list.files(system.file("libs", package = "openalexSnapshot"))) > 0)
})


test_that("every public function is actually exported in NAMESPACE", {
  # devtools::load_all() exposes unexported objects, so the rest of the suite
  # cannot catch a lost @export tag -- and one was lost this way, leaving
  # build_corpus_index() invisible to library() while all tests still passed.
  # getNamespaceExports() answers the question library() would ask. (Reading
  # NAMESPACE from the source tree does not survive R CMD check, which runs
  # the tests from an installed copy with no source layout around them.)
  exported <- getNamespaceExports("openalexSnapshot")
  expect_setequal(
    exported,
    c("build_citation_index", "build_corpus_index", "build_doi_index",
      "doi_to_id", "get_cited", "get_citing", "lookup_by_doi", "lookup_by_id")
  )
})

test_that("id extraction is generic, not works-only", {
  # Regression: a Stage-1 optimisation used position('/W' IN id), which returns
  # 0 for any non-works id, so every author/source/institution row landed in a
  # NULL block. Author ids in particular are the second-largest dataset.
  tmp <- withr::local_tempdir()
  d <- file.path(tmp, "parquet", "authors", "updated_date=2020-01-01")
  dir.create(d, recursive = TRUE)
  ids <- paste0("https://openalex.org/A",
                format(5000000000 + (0:9) * 200000, scientific = FALSE, trim = TRUE))
  arrow::write_parquet(data.frame(id = ids, display_name = paste("Author", 1:10)),
                       file.path(d, "part_0000.parquet"))

  idx <- build_corpus_index(corpus_dir = file.path(tmp, "parquet", "authors"),
                            backend = "r", verbose = FALSE)
  got <- dplyr::collect(arrow::open_dataset(
    list.files(idx, pattern = "part-0\\.parquet$", recursive = TRUE,
               full.names = TRUE)))
  expect_equal(nrow(got), 10L)
  expect_setequal(got$id, ids)

  # and they are spread over blocks rather than collapsing into one
  blocks <- grep("^id_block=", list.dirs(idx, recursive = FALSE,
                                         full.names = FALSE), value = TRUE)
  expect_gt(length(blocks), 1L)
  expect_false(any(grepl("id_block=__HIVE_DEFAULT", blocks)))

  # a lookup round-trips (id taken from the fixture, not hard-coded)
  want <- ids[3]
  back <- lookup_by_id(ids = sub(".*/", "", want), index_file = idx,
                       backend = "r", columns = "id", verbose = FALSE)
  expect_equal(back$id, want)
})

test_that("block_size adapts to the id range of the dataset", {
  # A fixed 1e7 gives works 351 blocks but authors only 14, because author ids
  # cluster in a narrow range. Deriving from the observed span fixes that.
  tmp <- withr::local_tempdir()
  wide <- file.path(tmp, "w"); dir.create(wide, recursive = TRUE)
  arrow::write_parquet(
    data.frame(id = paste0("https://openalex.org/W",
                           format(c(1e3, 7.1e9), scientific = FALSE, trim = TRUE))),
    file.path(wide, "part_0000.parquet"))
  narrow <- file.path(tmp, "n"); dir.create(narrow, recursive = TRUE)
  arrow::write_parquet(
    data.frame(id = paste0("https://openalex.org/A",
                           format(c(5.00e9, 5.13e9), scientific = FALSE, trim = TRUE))),
    file.path(narrow, "part_0000.parquet"))

  bw <- .oas_derive_block_size(list.files(wide, full.names = TRUE))
  bn <- .oas_derive_block_size(list.files(narrow, full.names = TRUE))
  expect_gt(bw, bn * 10)          # wide range -> much wider blocks
  expect_gte(bn, 1e4)             # floored
})

test_that(".oas_plan_batches() groups by byte budget, never by file count", {
  # The corpus is extremely skewed -- one updated_date partition holds 54% of
  # the works while hundreds hold megabytes -- so batching by directory or by
  # count produces wildly uneven work. Batch size is also what governs spill:
  # 8 GB batches spilled 23-31 GB each; 1 GB batches spill nothing.
  tmp <- withr::local_tempdir()
  mk <- function(name, kb) {
    p <- file.path(tmp, name)
    writeBin(raw(kb * 1024), p)
    p
  }
  files <- c(mk("a", 400), mk("b", 400), mk("c", 400), mk("d", 50), mk("e", 50))

  b <- .oas_plan_batches(files, batch_bytes = 1024 * 1024)   # 1 MB budget
  expect_setequal(unlist(b), files)                          # nothing dropped
  expect_equal(length(unlist(b)), length(files))             # nothing duplicated
  expect_true(all(vapply(b, length, integer(1)) >= 1L))

  # a file larger than the budget still gets its own batch rather than vanishing
  big <- mk("big", 4096)
  b2 <- .oas_plan_batches(c(files, big), batch_bytes = 1024 * 1024)
  expect_true(big %in% unlist(b2))

  # a generous budget collapses to one batch; a tiny one splits per file
  expect_length(.oas_plan_batches(files, batch_bytes = 1e12), 1L)
  expect_length(.oas_plan_batches(files, batch_bytes = 1L), length(files))
})

test_that(".oas_stage1_sql() emits the partitioned write the resume logic needs", {
  q <- .oas_stage1_sql(c("/c/a.parquet", "/c/b.parquet"),
                       "json_extract_string(w.referenced_works, '$[*]')",
                       1e7, "/tmp/shards", "b00007", "ZSTD")
  # FILENAME_PATTERN carries the batch tag: without it a failed batch's partial
  # output cannot be identified and cleared, and concurrent writers into one
  # shard tree would collide.
  expect_match(q, "FILENAME_PATTERN 'b00007_\\{i\\}'", fixed = FALSE)
  expect_match(q, "PARTITION_BY \\(cited_block\\)")
  expect_match(q, "OVERWRITE_OR_IGNORE")
  # both source files present, and the id extraction is the works-specific one
  expect_match(q, "/c/a.parquet", fixed = TRUE)
  expect_match(q, "/c/b.parquet", fixed = TRUE)
  expect_match(q, "position\\('/W' IN r.ref\\)")
})

test_that("parallel lookup workers do not spill into the working directory", {
  # Regression test. Every worker used to open .oas_con() with no temp_dir, so
  # they all inherited DuckDB's default `.tmp` -- which is relative to the
  # working directory -- and wrote colliding duckdb_temp_storage_*.tmp files
  # into one place. build_citation_index() documents that hazard; the lookup
  # path, which pro_snowball(snapshot=) drives in parallel, did not guard it.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)

  wd <- withr::local_tempdir()
  withr::local_dir(wd)

  got <- lookup_by_id(ids = tiny_ids()[1:3], index_file = idx, backend = "r",
                      columns = c("id"), workers = 2, verbose = FALSE)
  expect_equal(nrow(got), 3L)
  expect_false(dir.exists(file.path(wd, ".tmp")))
})

test_that("lookup_by_id exposes memory_limit and temp_dir", {
  fm <- formals(lookup_by_id)
  expect_true(all(c("memory_limit", "temp_dir") %in% names(fm)))
  expect_null(eval(fm$memory_limit))
  expect_null(eval(fm$temp_dir))
})

test_that("get_citing and get_cited expose temp_dir", {
  expect_true("temp_dir" %in% names(formals(get_citing)))
  expect_true("temp_dir" %in% names(formals(get_cited)))
})

test_that("lookup_by_id(output=) writes the same schema it returns", {
  # The COPY path used to keep the synthetic `file_row_number` column while
  # the in-memory path stripped it, so the two disagreed -- and any reader
  # that itself asked for file_row_number could not open the result at all.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  idx <- build_corpus_index(corpus_dir = corpus, backend = "r", verbose = FALSE)
  ids <- tiny_ids()[1:3]

  in_mem <- lookup_by_id(ids = ids, index_file = idx, backend = "r",
                         verbose = FALSE)
  out <- file.path(tmp, "written")
  lookup_by_id(ids = ids, index_file = idx, backend = "r", output = out,
               verbose = FALSE)
  written <- arrow::open_dataset(out) |> dplyr::collect()

  expect_false("file_row_number" %in% names(written))
  expect_setequal(names(written), names(in_mem))

  # and the written output must be re-readable with file_row_number = true
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  expect_no_error(
    DBI::dbGetQuery(con, sprintf(
      "SELECT count(*) FROM read_parquet('%s/**/*.parquet', file_row_number = true)",
      out
    ))
  )
})

test_that(".oas_ensure_json loads the json extension explicitly", {
  # DuckDB's autoinstall_known_extensions defaults to FALSE, so a machine
  # that has never installed `json` cannot autoload it: the first
  # json_extract_string() dies with "Extension Autoloading Error ... not
  # found". That is what broke every CI job here while passing locally,
  # where the extension is already cached. An explicit INSTALL works in
  # both places.
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  .oas_ensure_json(con)

  loaded <- DBI::dbGetQuery(
    con, "SELECT loaded FROM duckdb_extensions() WHERE extension_name = 'json'"
  )$loaded
  expect_true(isTRUE(loaded[[1L]]))
  expect_equal(
    DBI::dbGetQuery(
      con, "SELECT len(json_extract_string('[\"a\",\"b\"]', '$[*]')) AS n"
    )$n[[1L]],
    2L
  )
})

test_that("a JSON-text corpus loads json before using json_extract_string", {
  # .oas_refs_expr() is where the package decides it needs the extension, so
  # that is where it must be ensured. A native-list corpus must not pay for
  # it at all.
  tmp <- withr::local_tempdir()
  corpus <- make_tiny_corpus(tmp)
  # make_tiny_corpus() returns the works dataset directory itself.
  files <- list.files(corpus, pattern = "[.]parquet$",
                      recursive = TRUE, full.names = TRUE)
  expect_gt(length(files), 0L)
  con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  re <- .oas_refs_expr(con, files)
  expect_equal(re$enc, "json_varchar")

  # The returned expression must actually evaluate on this connection.
  n <- DBI::dbGetQuery(con, paste0(
    "SELECT count(*) AS n FROM read_parquet(", .oas_sql_str(.oas_fwd(files[1L])),
    ") AS w, LATERAL UNNEST(", re$expr, ") AS r(ref) ",
    "WHERE w.referenced_works IS NOT NULL"
  ))$n[[1L]]
  expect_gt(n, 0L)
})
