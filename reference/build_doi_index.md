# Build a Parquet DOI-lookup index

Builds a `<dataset>_doi_idx.parquet` index mapping normalised DOIs to
OpenAlex IDs and to their location in the Parquet corpus, so DOIs can be
resolved without network access.

## Usage

``` r
build_doi_index(
  root_dir = NULL,
  data_sets = "works",
  workers = NULL,
  memory_limit = NULL,
  temp_dir = NULL,
  batch_bytes = 8e+09,
  compression = "zstd",
  overwrite = FALSE,
  verbose = TRUE,
  corpus_dir = NULL
)
```

## Arguments

- root_dir:

  Root directory containing a `parquet/` subdirectory, or the parquet
  directory itself.

- data_sets:

  Datasets to index. Only `works` carries a `doi` column, so the default
  is `"works"`.

- workers:

  Number of parallel workers for Stage 1.

- memory_limit:

  DuckDB memory limit, e.g. `"20GB"`.

- temp_dir:

  Directory for Stage-1 shards and DuckDB spill. Defaults to a
  subdirectory of [`tempdir()`](https://rdrr.io/r/base/tempfile.html),
  which is on local disk, named after the index and a hash of the corpus
  path, so that only a re-run of the same build resumes from it.

  The default matters. Spilling beside the index puts those writes on
  the same device the corpus is being read from, and on an external USB
  SSD that measured **8.18 s/batch versus 0.76 s/batch** – a 10.8x
  difference from this setting alone. Override it only to point at a
  *different* fast disk, or if the default lacks room: peak usage is
  roughly the size of the finished index plus its transient shards.

- batch_bytes:

  Approximate bytes of source parquet per Stage-1 batch.

- compression:

  Parquet compression codec.

- overwrite:

  Rebuild an existing index.

- verbose:

  Print progress.

- corpus_dir:

  Explicit path to a single dataset Parquet directory. When given,
  `root_dir` and `data_sets` are ignored.

## Value

Invisibly, the path to the index file (`corpus_dir` mode) or `root_dir`.

## Details

The corpus stores DOIs as full lower-cased resolver URLs
(`https://doi.org/10.1097/...`). The index key is the **bare** DOI, so
that a caller may supply any of these and get the same answer:

    10.1016/j.joi.2017.08.007
    https://doi.org/10.1016/j.joi.2017.08.007
    http://dx.doi.org/10.1016/j.joi.2017.08.007
    doi:10.1016/j.joi.2017.08.007
    DOI: 10.1016/J.JOI.2017.08.007

Carrying `parquet_file` and `file_row_number` alongside the ID means
[`lookup_by_doi()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_doi.md)
can extract full records from one index read rather than two.

The index contains:

- doi:

  Normalised bare lower-case DOI, no resolver prefix

- id:

  OpenAlex ID in long form

- id_block:

  `floor(numeric_id / 10000)`, as in the ID index

- parquet_file:

  Path relative to the parquet root

- file_row_number:

  Row number within that file (0-indexed)

Rows are sorted by `doi`, so a point lookup reads the footer plus one
row group rather than scanning the file.

## See also

[`doi_to_id()`](https://openalexpro.github.io/openalexSnapshot/reference/doi_to_id.md),
[`lookup_by_doi()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_doi.md),
[`build_corpus_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_corpus_index.md)
