# Resolve DOIs to OpenAlex IDs offline

Looks DOIs up in the index built by
[`build_doi_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_doi_index.md).
DOIs may be given with or without a resolver prefix; all of these
resolve identically:

## Usage

``` r
doi_to_id(
  doi,
  root_dir = NULL,
  index_file = NULL,
  data_set = "works",
  verbose = TRUE
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

- data_set:

  Dataset name used to locate the index under `root_dir`.

- verbose:

  Print progress.

## Value

A data frame with one row per input, in input order:

- doi_input:

  The string as supplied

- doi:

  Its normalised key

- id:

  The OpenAlex ID in long form, or `NA` if unresolved

A data frame rather than a bare vector, because the caller needs to know
*which* inputs failed to resolve.

## Details

    10.1016/j.joi.2017.08.007
    https://doi.org/10.1016/j.joi.2017.08.007
    http://dx.doi.org/10.1016/j.joi.2017.08.007
    doi:10.1016/j.joi.2017.08.007
    DOI: 10.1016/J.JOI.2017.08.007

## See also

[`build_doi_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_doi_index.md),
[`lookup_by_doi()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_doi.md)
