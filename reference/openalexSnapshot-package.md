# openalexSnapshot: OpenAlex Bulk Snapshot Conversion, Indexing, and Record Extraction

Provides tools for working with the OpenAlex bulk snapshot: converting
.json.gz files to Parquet format, building ID, DOI and inverted-citation
indexes over the resulting corpus, and extracting records by OpenAlex ID
or DOI. Also provides an offline view of the citation graph, so the
works citing or cited by a given paper can be retrieved without network
access. Indexing and extraction are implemented in R over DuckDB. The
package is pure R: no compiled code, and no Rust toolchain is needed to
install it.

## See also

Useful links:

- <https://github.com/openalexPro/openalexSnapshot>

- <https://openalexpro.github.io/openalexSnapshot/>

- [doi:10.5281/zenodo.20448992](https://doi.org/10.5281/zenodo.20448992)

- Report bugs at
  <https://github.com/openalexPro/openalexSnapshot/issues>
