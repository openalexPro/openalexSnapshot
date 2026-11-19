# Build an inverted citation index

Inverts the `referenced_works` column of the works corpus into an edge
set keyed by the **cited** work, so that "which works cite X?" becomes a
point lookup instead of a full-corpus scan. This is what makes
[`get_citing()`](https://openalexpro.github.io/openalexSnapshot/reference/get_citing.md)
possible offline: the snapshot's `cited_by_api_url` is a URL and useless
without network access, but the citing direction is recoverable by
inverting the references every work already carries.

## Usage

``` r
build_citation_index(
  root_dir = NULL,
  data_sets = "works",
  workers = NULL,
  memory_limit = NULL,
  retry_memory_limit = "12GB",
  temp_dir = NULL,
  block_size = 1e+07,
  batch_bytes = 1e+09,
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

  Datasets to index. Only works carry `referenced_works`, so the default
  is `"works"`.

- workers:

  Number of parallel workers.

- memory_limit:

  DuckDB memory limit per worker, e.g. `"8GB"`.

- retry_memory_limit:

  Memory limit for the sequential retry of batches that exceeded
  `memory_limit` during the parallel pass. Peak memory depends on how
  reference-dense a batch's works happen to be, which varies enough
  across the corpus that no single per-worker limit suits every batch;
  rather than sizing `memory_limit` for the worst batch and throttling
  all of them, dense batches are re-run alone with the whole machine.

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

- block_size:

  Width of a `cited_block`. The default `1e7` yields ~351 partitions
  over the full corpus, averaging tens of MB each. Do **not** use the ID
  index's `floor(n / 1e4)`: the largest OpenAlex work ID would give over
  700,000 partitions.

- batch_bytes:

  Approximate bytes of source parquet per Stage-1 batch. Batching is by
  byte budget over the flat file list rather than by hive partition,
  because the corpus is extremely skewed – one `updated_date=` partition
  can hold half the works while hundreds hold megabytes.

  The default of 1 GB is measured, not guessed. Unnesting a batch and
  writing it across hundreds of partitions costs far more memory than
  the few MB it emits, so the batch size governs spill. On the dense
  files of the real corpus, at `memory_limit = "3GB"`: a 1 GB batch
  takes ~2.4 s with **no spill**; a 2 GB batch takes ~15 s; a 4 GB batch
  runs **out of memory**. An earlier 8 GB default spilled 23-31 GB per
  batch and was roughly six times slower overall. Raise this only
  alongside `memory_limit`, and measure.

- compression:

  Parquet compression codec.

- overwrite:

  Rebuild an existing index.

- verbose:

  Print progress.

- corpus_dir:

  Explicit path to a single dataset Parquet directory.

## Value

Invisibly, the path to the index directory (`corpus_dir` mode) or
`root_dir`.

## Details

[`get_cited()`](https://openalexpro.github.io/openalexSnapshot/reference/get_citing.md)
does **not** need this index – the works a paper references are simply
its own `referenced_works` – so only one index is built, not a pair.

Each part file holds:

- cited_id:

  The cited work's OpenAlex ID, long form `VARCHAR`

- citing_id:

  The citing work's OpenAlex ID, long form `VARCHAR`

sorted by `(cited_id, citing_id)`, matching the long-form convention of
`<dataset>_id_idx/` and `<dataset>_doi_idx.parquet` so every index in
the family stores IDs the same way. Note this costs real space at three
billion rows: `citing_id` is effectively random within a block and so
does not dictionary-compress, unlike the sorted `cited_id`.

## Layout

Like `<dataset>_id_idx/`, this index is a **hive-partitioned directory**
(only `<dataset>_doi_idx.parquet` remains a single file):

    works_cite_idx/
      _index_meta.parquet
      cited_block=0/part-0.parquet
      cited_block=1/part-0.parquet
      ...

The reason is scale. The full OpenAlex works corpus holds roughly three
billion reference edges; a single sorted file would need a global sort
of that many rows, and its footer alone would cost tens of megabytes to
parse on every query. Partitioning by a coarse block of the cited ID
keeps each part small enough to sort in memory and lets a lookup open
only the handful of parts it needs.

`_index_meta.parquet` is written **last**; its presence is what marks
the index complete, and it records the `block_size` the query side must
use.

## See also

[`get_citing()`](https://openalexpro.github.io/openalexSnapshot/reference/get_citing.md),
[`get_cited()`](https://openalexpro.github.io/openalexSnapshot/reference/get_citing.md)
