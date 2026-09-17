[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.20448992.svg)](https://doi.org/10.5281/zenodo.20448992)
[![Lifecycle: experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html)
[![License: GPL-2+](https://img.shields.io/badge/License-GPL%20%3E%3D%202-blue.svg)](https://www.gnu.org/licenses/gpl-2.0)
[![Codecov](https://codecov.io/gh/openalexPro/openalexSnapshot/graph/badge.svg)](https://app.codecov.io/gh/openalexPro/openalexSnapshot)

<!-- README.md is generated from README.Rmd. Please edit that file -->

# openalexSnapshot

<!-- badges: start -->
[![r-universe](https://rkrug.r-universe.dev/badges/openalexSnapshot)](https://rkrug.r-universe.dev/openalexSnapshot)
<!-- badges: end -->

`openalexSnapshot` converts the [OpenAlex bulk
snapshot](https://docs.openalex.org/download-all-data/openalex-snapshot)
from gzipped newline-delimited JSON to Parquet, builds fast ID-lookup
indexes, and extracts individual records by OpenAlex ID. The heavy
lifting is done by a compiled Rust library (statically linked via
[extendr](https://extendr.github.io/)), with no external binary
dependency. For API-based access to OpenAlex, see
[openalexPro](https://openalexpro.github.io/openalexPro).

## Installation

Install from r-universe (precompiled binaries available for macOS and
Linux — no Rust toolchain required):

``` r
install.packages(
  "openalexSnapshot",
  repos = c("https://rkrug.r-universe.dev", "https://cloud.r-project.org")
)
```

Install the development version from GitHub:

``` r
# install.packages("pak")
pak::pak("openalexPro/openalexSnapshot")
```

## Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Disk space | 2.5 TB | 3+ TB |
| RAM | 16 GB | 32+ GB |
| CPU | 2 cores | 4+ cores |

## Quick Start

``` r
library(openalexSnapshot)

root <- "/Volumes/openalex"

# OpenAlex now publishes the snapshot natively in Parquet, so there is no
# JSON conversion step.

# 1. Build the ID index (record lookup)
build_corpus_index(
  root_dir  = root,
  data_sets = "works",
  workers   = 4
)

# 2. Build the citation index (who cites whom). This inverts
#    referenced_works, which is what makes the forward direction possible
#    offline -- cited_by_api_url is a URL and cannot be used.
build_citation_index(root_dir = root, workers = 4)

# 3. Look up records by OpenAlex ID. `columns` matters: works carry ~51
#    columns of nested structs and extracting all of them dominates the run.
works <- lookup_by_id(
  root_dir = root,
  ids      = c("W2741809807", "W2100837269"),
  columns  = c("id", "doi", "title", "publication_year")
)

# 4. Walk the citation graph
citing <- get_citing("W2741809807", root_dir = root)   # works citing it
cited  <- get_cited("W2741809807",  root_dir = root)   # works it cites
```

## Documentation

Full documentation and articles are available at
<https://openalexpro.github.io/openalexSnapshot>.

- [Working with the OpenAlex Bulk
  Snapshot](https://openalexpro.github.io/openalexSnapshot/articles/snapshot-workflow.html)
  — download, convert, index, and query the full snapshot
- [Snapshot Conversion: From JSON to
  Parquet](https://openalexpro.github.io/openalexSnapshot/articles/snapshot-conversion.html)
  — detailed function reference

## Related packages

- [openalexPro](https://openalexpro.github.io/openalexPro) — API access,
  tidy data frames, and advanced OpenAlex workflows
