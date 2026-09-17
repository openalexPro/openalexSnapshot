# openalexSnapshot 0.3.1

## Bug fix: the `json` extension is now installed explicitly

Every CI job failed -- and would fail on any machine that had not already
used DuckDB's `json` extension -- with

```
Extension Autoloading Error: An error occurred while trying to
automatically install the required extension 'json'
```

`referenced_works` is stored as JSON text in some corpora, and reading it
uses `json_extract_string()`. The package relied on DuckDB autoloading the
extension on demand, but `autoinstall_known_extensions` defaults to **FALSE**,
so autoloading can only succeed where the extension happens to already be
installed. It is, on a developer machine that has used it before; it is not,
on a fresh runner. That is why the suite passed locally and failed everywhere
else. (openalexPro has always run `INSTALL json` explicitly, which is why its
CI was unaffected.)

New internal `.oas_ensure_json()` runs `INSTALL json; LOAD json;` and is
called from the two places that decide JSON text is in play --
`.oas_refs_expr()` and `get_cited()`'s reference unnesting -- so a corpus
whose `referenced_works` is a native list still needs no extension at all.
If the install fails, the error now says what is missing and how to install
it, rather than surfacing DuckDB's autoload message.

# openalexSnapshot 0.3.0

## Bug fix: parallel lookup workers shared one spill directory

`.oas_lookup_one_index()` opened each worker's DuckDB connection with no
`temp_dir`, so every worker in the pool inherited DuckDB's default -- `.tmp`,
*relative to the working directory*. Concurrent instances then wrote colliding
`duckdb_temp_storage_*.tmp` files into one place and corrupted each other's
spill. This is exactly the hazard `build_citation_index()` documents and
guards against; the lookup path, which `pro_snowball(snapshot = )` drives in
parallel, did not.

Each worker now gets a private directory under `tempdir()`, removed on exit.
`get_citing()` and `get_cited()` get the same treatment for their own
connections, which matters when several callers run at once.

## `lookup_by_id()` can be given a memory budget

`.oas_lookup_one_index()` has always accepted `memory_limit`, but the exported
`lookup_by_id()` had no such argument and never passed one, so it was
unreachable -- every worker ran at DuckDB's default of ~80% of system RAM,
*each*. `lookup_by_id()` now takes `memory_limit` and `temp_dir` and forwards
both; `get_citing()` / `get_cited()` gain `temp_dir` alongside the
`memory_limit` they already had.

# openalexSnapshot 0.2.0

## New: offline citation graph

The snapshot can now answer "which works cite this one?" without network
access. `cited_by_api_url` is a URL and useless offline, but the citing
direction is recoverable by inverting the `referenced_works` every work
already carries.

* **`build_citation_index()`** inverts `referenced_works` into an edge set
  keyed by the cited work. Unlike the `_id_idx` and `_doi_idx` files this is a
  hive-partitioned **directory** (`works_cite_idx/cited_block=N/`), because the
  full corpus holds roughly three billion edges: a single sorted file would
  need a global sort of that many rows and a footer costing tens of MB to parse
  per query. Measured on the real corpus this costs about 5 bytes per edge
  (~15 GB total) and turns a 20-second scan into a 5-millisecond lookup.

* **`build_doi_index()`** builds `works_doi_idx.parquet`, so DOIs resolve
  offline. DOIs are accepted with or without a resolver prefix -- bare,
  `https://doi.org/`, `http://dx.doi.org/`, `doi:` and mixed case all normalise
  to the same key.

* **`get_citing()`** and **`get_cited()`** query the above. `keypaper` is a
  vector and may mix short IDs, long IDs, bare DOIs and resolver DOIs in one
  call; all are resolved and queried in a single pass. The default return is an
  edge list (`from`, `to`, where a row `A, B` means A cites B) rather than a
  flat ID vector, which keeps the mapping between each keypaper and its
  neighbours. `return = "ids"` and `return = "records"` are also available.

  `get_cited()` deliberately needs **no** citation index: the works a paper
  references are simply its own `referenced_works`.

* **`doi_to_id()`** and **`lookup_by_doi()`** resolve and extract by DOI.
  Unresolved DOIs are returned as `NA` in input order and warned about, never
  silently dropped.

* Missing indexes raise typed conditions
  (`openalexSnapshot_missing_citation_index` and friends) naming the builder
  that creates them, and distinguish an absent index from an interrupted build.
  An index that looks out of step with the corpus **warns rather than errors** --
  a deliberately frozen snapshot must stay usable.

## The package is now pure R

* **All compiled code is removed.** No `src/`, no `configure`, no
  `SystemRequirements`, no Rust toolchain to install the package. The
  `openalex-core` git dependency -- pinned at `v0.5.0`, a major version behind
  -- is gone with it.

* **`snapshot_to_parquet()` is removed.** OpenAlex publishes the snapshot
  natively in parquet, so converting from JSON is a dead path. It was also the
  only function with no R implementation.

* **`oa_snapshot_to_parquet()`, `oa_build_corpus_index()` and
  `oa_lookup_by_id()` are removed** -- the direct wrappers around the compiled
  functions.

* **`backend = "rust"` now raises an explanatory error** rather than being
  silently ignored, so existing calls say why. `backend = "auto"` and `"r"`
  both use the R implementation, which is what they already did in practice.

  The R implementation is not a fallback; it is the better one. It writes a
  sorted index and supports `columns`/`add_columns`, neither of which the
  compiled path could do.

## The ID index is now a partitioned directory

* **`<dataset>_id_idx.parquet` becomes `<dataset>_id_idx/`**, hive-partitioned
  by `id_block = floor(numeric_id / 1e7)` with each block sorted by `id` —
  the same shape as `<dataset>_cite_idx/`. Over the full works corpus that is
  351 non-empty blocks for 492,361,307 rows.

  A single file cost on both sides. Reading: 3,992 row groups whose footer had
  to be parsed on **every** query, measured at 0.192 s before touching any
  data. Building: a global sort of 492 M rows. Partitioning removes both —
  blocks sort independently in memory, and a lookup opens only the blocks its
  ids fall in, never parsing the others' footers.

* `lookup_by_id()` builds its partition file list in R from the ids rather than
  globbing the index, for the same reason `get_citing()` does.

* The `id_block` column at `floor(n / 1e4)` granularity is **gone** from the
  index rows. It was documented from the start as the mechanism for avoiding a
  full index scan, and nothing ever used it; at 1e4 it would have produced
  714,000 partitions, which is unusable. The partition key reuses the name at
  the `1e7` granularity that works, and `block_size` is recorded in
  `_index_meta.parquet` for the query side to recompute with.

## Indexes are written sorted

* **`build_corpus_index()` now sorts `<dataset>_id_idx.parquet` by
  `(id_block, id)`**, and `lookup_by_id()` filters on `id_block` before `id`.
  Previously the index was unsorted, so every lookup scanned the whole file --
  1.87 s per call on the real 7.29 GB works index, four calls per snowball.
  The `id_block` column existed and was documented for precisely this purpose
  but nothing ever used it.

  Existing indexes are not sorted; rebuild with `overwrite = TRUE` to benefit.
  An unsorted index still returns correct results, just slowly.

* **`backend = "auto"` resolves to `"r"`, and `backend = "rust"` is
  deprecated** (warning once per session, removal in a future release). The R
  builder writes a sorted index and supports `columns`/`add_columns`; the Rust
  builder does neither, so preferring it whenever the compiled library happened
  to be loaded silently produced a worse index.

  `snapshot_to_parquet()` is unaffected and remains Rust-only -- there is no R
  implementation of it to fall back to.

## Design change: pure R by default, Rust as an optional accelerator

* **The "Rust-only, no pure-R fallback" decision recorded in 0.0.0.9000 is
  retracted.** Part 4 of the ecosystem `compatibility_report.md` measured the
  actual benefit: for `index` and `extract` the work is parquet decode and
  write rather than computation, a single DuckDB thread already saturates the
  pipeline, and the corpus lives on an external volume where cold I/O dominates
  and is language-neutral. The expected Rust advantage is ~1.0-1.5x. `enrich`
  was the one genuine win (~10x), and moving enrichment from download-time to
  extract-time removes that step in batch form entirely.

* `build_corpus_index()` and `lookup_by_id()` gain
  `backend = c("auto", "r", "rust")`. `"auto"` (the default) uses the compiled
  library when it is loaded and pure R otherwise, so **existing behaviour is
  unchanged**. `"r"` is always available and is what CI exercises.

* `lookup_by_id()` gains `columns =` (column projection) and `add_columns =`
  (inject constant columns). Both were impossible on the Rust path, which does
  `SELECT *`; projection matters when reading 2 of 51 columns from a corpus of
  nested structs.

* `snapshot_to_parquet()` remains **Rust-only**. It is the hardest to port, it
  is not on the critical path, and the official OpenAlex snapshot is now
  published natively in parquet, making JSON conversion a legacy path.

* `DESCRIPTION` previously claimed "a pure-R/DuckDB fallback is included for
  environments without a Rust toolchain", which was not true of the shipped
  code. It is now accurate. `SystemRequirements` records that Rust is needed
  only for `snapshot_to_parquet()`.

* Added the missing `VignetteBuilder: quarto` — the two `.qmd` vignettes could
  not previously be built.

# openalexSnapshot 0.0.0.9000

* Package created. Snapshot conversion (`snapshot_to_parquet()`), corpus
  indexing (`build_corpus_index()`), and ID-based record extraction
  (`lookup_by_id()`) have been split out of **openalexPro** into this dedicated
  package. Function signatures are preserved from the original openalexPro
  versions.
* **Rust-only design**: no pure-R fallback is planned. Installation friction is
  addressed by pre-compiled r-universe binaries rather than a second
  implementation. Only package developers need a Rust toolchain.
  **Retracted in 0.1.0** — see below.
* Rust back-end (`openalex-core` via extendr) wired up; all three functions
  delegate to compiled Rust code.
