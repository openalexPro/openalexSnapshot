# Mock the Rust-level entry points so the R logic can be tested without
# a compiled library.  Each mock records its call arguments in `last_call`
# so tests can assert what was passed through.

mock_oa_build_corpus_index <- function(corpus_dir, workers, memory_limit,
                                       overwrite, verbose) {
  last_call <<- list(
    fn           = "oa_build_corpus_index",
    corpus_dir   = corpus_dir,
    workers      = workers,
    memory_limit = memory_limit,
    overwrite    = overwrite,
    verbose      = verbose
  )
  paste0(corpus_dir, "_id_idx.parquet")   # return a plausible index path
}

mock_oa_lookup_by_id <- function(index_file, ids, output, workers, verbose) {
  last_call <<- list(
    fn         = "oa_lookup_by_id",
    index_file = index_file,
    ids        = ids,
    output     = output,
    workers    = workers,
    verbose    = verbose
  )
  # Create a dummy parquet file in output so lookup_by_id() can read it back.
  if (!is.null(output) && nzchar(output)) {
    dir.create(output, recursive = TRUE, showWarnings = FALSE)
  }
  invisible(NULL)
}


# -- parquet fixture ---------------------------------------------------------
# A tiny works corpus with the real column shapes, built in tempdir(). Used by
# every pure-R test: those must not skip on a machine without a Rust toolchain,
# which rules out the .gz fixtures that only the compiled converter can read.
#
# Deliberately includes the awkward cases: a NULL referenced_works, an empty
# '[]' one, a work with no DOI, and a SICI DOI containing < > [ ] (the regression
# anchor for the openalexPro::extract_doi() truncation bug).

source(system.file("testdata/make_tiny_corpus.R", package = "openalexSnapshot"),
       local = FALSE)
