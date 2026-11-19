# Find the works citing, or cited by, given keypapers

`get_citing()` returns the works that **cite** the keypapers;
`get_cited()` returns the works the keypapers **reference**. Both work
entirely offline against a local snapshot.

## Usage

``` r
get_citing(
  keypaper,
  root_dir = NULL,
  return = c("edges", "ids", "records"),
  output = NULL,
  columns = NULL,
  max_results = 100000L,
  depth = 1L,
  citation_index = NULL,
  id_index = NULL,
  doi_index = NULL,
  data_set = "works",
  workers = NULL,
  memory_limit = NULL,
  temp_dir = NULL,
  verbose = TRUE
)

get_cited(
  keypaper,
  root_dir = NULL,
  return = c("edges", "ids", "records"),
  output = NULL,
  columns = NULL,
  max_results = 100000L,
  depth = 1L,
  id_index = NULL,
  doi_index = NULL,
  data_set = "works",
  workers = NULL,
  memory_limit = NULL,
  temp_dir = NULL,
  verbose = TRUE
)
```

## Arguments

- keypaper:

  Character **vector** of one or more keypapers. Forms may be mixed
  freely in a single call:

  - short OpenAlex ID, `"W3045921891"`

  - long OpenAlex ID, `"https://openalex.org/W3045921891"`

  - bare DOI, `"10.1016/j.joi.2017.08.007"`

  - DOI with resolver, `"https://doi.org/10.7717/peerj.4375"`

  All keypapers are resolved and queried in one pass, not in a loop.

- root_dir:

  Root directory containing a `parquet/` subdirectory, or the parquet
  directory itself.

- return:

  What to return:

  - `"edges"` (default) – a data frame of `from`/`to` long-form IDs,
    where a row `A, B` means **A cites B**. This keeps the mapping
    between each keypaper and its neighbours, which a flat ID vector
    would lose when `keypaper` has length \> 1, and it is directly
    `rbind`-able into a snowball edge set.

  - `"ids"` – the unique non-keypaper endpoint, as a character vector.

  - `"records"` – the full records for those IDs, via
    [`lookup_by_id()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_id.md).

- output:

  Directory to write records to when `return = "records"`. When `NULL`,
  records are returned as a data frame.

- columns:

  Column projection passed to
  [`lookup_by_id()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_id.md)
  when `return = "records"`.

- max_results:

  Error if more edges than this are found. A single heavily cited work
  can have hundreds of thousands of citing works, and the follow-on
  record extraction would then touch essentially every file in the
  corpus. Set `Inf` to lift the guard deliberately.

- depth:

  Reserved for multi-hop snowballing; only `1` is implemented.

- citation_index:

  Explicit path to a `*_cite_idx` directory.

- id_index:

  Explicit path to a `*_id_idx` directory.

- doi_index:

  Explicit path to a `*_doi_idx.parquet`.

- data_set:

  Dataset name used to locate indexes under `root_dir`.

- workers:

  Parallel workers for record extraction.

- memory_limit:

  DuckDB memory limit.

- temp_dir:

  Root for DuckDB's spill files. `NULL` (default) uses a private
  directory under [`tempdir()`](https://rdrr.io/r/base/tempfile.html).
  Never DuckDB's own default, which is `.tmp` relative to the working
  directory and is therefore shared by every concurrent caller.

- verbose:

  Print progress.

## Value

A data frame of edges, a character vector of IDs, or records – see
`return`.

## Details

The two are not symmetric in cost. `get_cited()` only needs the
keypaper's own `referenced_works` column, so it uses the ID index alone.
`get_citing()` asks the opposite question, which the snapshot does not
answer directly – `cited_by_api_url` is a URL – so it needs the inverted
index from
[`build_citation_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_citation_index.md).

## See also

[`build_citation_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_citation_index.md),
[`build_doi_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_doi_index.md),
[`lookup_by_id()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_id.md)
