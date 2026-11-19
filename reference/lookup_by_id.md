# Look up records by OpenAlex ID

Uses a pre-built index (created by
[`build_corpus_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_corpus_index.md))
to locate records efficiently and extract them from the Parquet corpus.

## Usage

``` r
lookup_by_id(
  root_dir = NULL,
  ids,
  project_dir = NULL,
  data_sets = NULL,
  workers = NULL,
  progress = TRUE,
  verbose = TRUE,
  index_file = NULL,
  output = NULL,
  backend = c("auto", "r", "rust"),
  columns = NULL,
  add_columns = NULL,
  memory_limit = NULL,
  temp_dir = NULL
)
```

## Arguments

- root_dir:

  Root directory containing `parquet/` and the dataset indexes produced
  by
  [`build_corpus_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_corpus_index.md).
  Index files are expected at `<root_dir>/parquet/<dataset>_id_idx/`.

- ids:

  Character vector of OpenAlex IDs to retrieve. Can be long form (e.g.
  `"https://openalex.org/W2741809807"`) or short form (e.g.
  `"W2741809807"`). Duplicates are dropped: each id is returned at most
  once. If the index holds an id in more than one source file, the
  record from the latest `updated_date=` partition is kept.

- project_dir:

  Project output directory. Extracted Parquet files are written to
  `<project_dir>/snapshot_extract_<dataset>/`. Only used when `root_dir`
  is provided.

- data_sets:

  Character vector of dataset names to search (e.g.
  `c("works", "authors")`). `NULL` searches all indexed datasets under
  `<root_dir>/parquet/`. Ignored when `index_file` is provided.

- workers:

  Number of parallel workers for reading corpus files. Default is `NULL`
  (sequential).

- progress:

  Ignored (kept for backward compatibility).

- verbose:

  Print progress messages. Default is `TRUE`.

- index_file:

  Explicit path to an index Parquet file created by
  [`build_corpus_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_corpus_index.md).
  When provided, `root_dir`, `data_sets`, and `project_dir` are ignored.

- output:

  Path to an output directory for writing results as Parquet files when
  using `index_file` mode. If `NULL` (default), results are returned as
  a data frame. Ignored when `root_dir` is used (use `project_dir`
  instead). Each source file is written to its own part, and a file that
  fails to read or write is an error, not a warning.

- backend:

  Retained only so that existing calls passing `backend = "rust"` get an
  explanatory error. The compiled backend was removed in 0.1.0; the
  package is pure R. `"auto"` (the default) and `"r"` both use the
  pure-R/DuckDB implementation. `"rust"` uses the compiled library and
  is **deprecated**: it writes an unsorted index and supports neither
  `columns` nor `add_columns`. It will be removed in a future release.
  `"auto"` (the default) uses the compiled Rust library when it is
  loaded and the pure-R/DuckDB implementation otherwise. `"r"` forces
  pure R and is always available. `"rust"` forces the compiled path and
  errors if it is not loaded.

- columns:

  Character vector of columns to return. `NULL` (default) returns all.
  Projection matters: reading 2 of 51 columns from a corpus of nested
  structs is far cheaper than `SELECT *`. Requires `backend = "r"` - the
  compiled path always reads every column.

- add_columns:

  Named list of constant columns to add to every returned row, e.g.
  `list(relation = "citing")`. Values are embedded as **SQL string
  literals**, matching `openalexPro::pro_request_parquet()`, so a
  logical must be passed as `"TRUE"` and cast by the caller. Requires
  `backend = "r"`.

- memory_limit:

  DuckDB `memory_limit` for each worker. `NULL` (default) leaves
  DuckDB's own, which is ~80% of system RAM *per worker*.

- temp_dir:

  Root for DuckDB's spill files. `NULL` (default) uses a private
  per-worker directory under
  [`tempdir()`](https://rdrr.io/r/base/tempfile.html). Workers must not
  share one: concurrent DuckDB instances write colliding
  `duckdb_temp_storage_*.tmp` files and corrupt each other's spill.

## Value

- `index_file` mode, `output` not `NULL`: invisibly returns `output`.

- `index_file` mode, `output` is `NULL`: returns a data frame of
  matching records.

- `root_dir` mode: invisibly returns `project_dir`.

## Details

Paths can be supplied as a `root_dir` + `data_sets` pair (which
automatically locates the correct index files and writes output into
`project_dir`) or as an explicit `index_file` for direct use.

## See also

[`build_corpus_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_corpus_index.md)
for building the required index.

## Examples

``` r
if (FALSE) { # \dontrun{
# root_dir mode (searches multiple datasets)
lookup_by_id(
  root_dir    = "/Volumes/openalex",
  ids         = c("W2741809807", "W1234567890"),
  project_dir = "my_project",
  data_sets   = "works"
)

# index_file mode (direct access, returns data frame)
records <- lookup_by_id(
  index_file = "works_id_index.parquet",
  ids        = c("W2741809807", "W1234567890")
)

# index_file mode (write to parquet)
lookup_by_id(
  index_file = "works_id_index.parquet",
  ids        = large_id_vector,
  output     = "filtered_works",
  workers    = 3
)
} # }
```
