# Look up records by DOI

Convenience wrapper:
[`doi_to_id()`](https://openalexpro.github.io/openalexSnapshot/reference/doi_to_id.md)
followed by
[`lookup_by_id()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_id.md).

## Usage

``` r
lookup_by_doi(
  doi,
  root_dir = NULL,
  index_file = NULL,
  id_index = NULL,
  data_set = "works",
  verbose = TRUE,
  ...
)
```

## Arguments

- doi:

  Character vector of DOIs.

- root_dir:

  Root directory containing a `parquet/` subdirectory, or the parquet
  directory itself.

- index_file:

  Explicit path to a `*_doi_idx.parquet`. Overrides `root_dir`.

- id_index:

  Explicit path to a `*_id_idx` directory.

- data_set:

  Dataset name used to locate the index under `root_dir`.

- verbose:

  Print progress.

- ...:

  Passed to
  [`lookup_by_id()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_id.md),
  e.g. `columns` or `output`.

## Value

Whatever
[`lookup_by_id()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_id.md)
returns.

## See also

[`doi_to_id()`](https://openalexpro.github.io/openalexSnapshot/reference/doi_to_id.md),
[`lookup_by_id()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_id.md)
