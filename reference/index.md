# Package index

## Snapshot Processing

Building and querying ID indexes over a local Parquet corpus.

- [`build_corpus_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_corpus_index.md)
  : Build a Parquet ID-lookup index
- [`lookup_by_id()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_id.md)
  : Look up records by OpenAlex ID

## Offline Citation Graph

Indexes and queries that make the citation graph available without
network access.

- [`build_citation_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_citation_index.md)
  : Build an inverted citation index
- [`build_doi_index()`](https://openalexpro.github.io/openalexSnapshot/reference/build_doi_index.md)
  : Build a Parquet DOI-lookup index
- [`get_citing()`](https://openalexpro.github.io/openalexSnapshot/reference/get_citing.md)
  [`get_cited()`](https://openalexpro.github.io/openalexSnapshot/reference/get_citing.md)
  : Find the works citing, or cited by, given keypapers
- [`doi_to_id()`](https://openalexpro.github.io/openalexSnapshot/reference/doi_to_id.md)
  : Resolve DOIs to OpenAlex IDs offline
- [`lookup_by_doi()`](https://openalexpro.github.io/openalexSnapshot/reference/lookup_by_doi.md)
  : Look up records by DOI

## Package

- [`openalexSnapshot`](https://openalexpro.github.io/openalexSnapshot/reference/openalexSnapshot-package.md)
  [`openalexSnapshot-package`](https://openalexpro.github.io/openalexSnapshot/reference/openalexSnapshot-package.md)
  : openalexSnapshot: OpenAlex Bulk Snapshot Conversion, Indexing, and
  Record Extraction
