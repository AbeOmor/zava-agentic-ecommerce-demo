# Zava curated demo database

This setup loads the repository's curated 60-row product dataset into the
`build_2026` database for the Zava Designer Agent.

The original Build demo used a separate 100K-row catalog that is not stored in
this repository. The curated seed contains all six UI categories and four of
the five deterministic boosted product IDs.

## Objects

- `public.product_metadata_demo`
- `public.semantic_dictionary`
- `idx_product_bm25`
- `idx_product_diskann`
- `zava_ai.search(...)`
- Extensions: `vector`, `pg_textsearch`, `pg_diskann`, `azure_ai`

The setup is intentionally idempotent. It recreates only the Zava product table
and search indexes.

`zava_ai.search(...)` is an application compatibility helper, not a built-in
HorizonDB capability. It composes native `pg_textsearch` BM25 search, `pg_diskann`
vector search, Azure OpenAI embeddings, and reciprocal-rank fusion.

Run `install_search_helper.sql` after loading the curated data and creating the
indexes.
