\set ON_ERROR_STOP on

SET search_path = public, "$user";

DROP INDEX IF EXISTS public.idx_product_fts;
DROP INDEX IF EXISTS public.idx_product_bm25;
DROP INDEX IF EXISTS public.idx_product_diskann;
DROP INDEX IF EXISTS public.idx_product_enrichment_bm25;
DROP INDEX IF EXISTS public.idx_product_enrichment_diskann;

CREATE INDEX idx_product_enrichment_bm25
ON public.product_catalog_enrichment_output
USING bm25 (chunk_text)
WITH (text_config = 'english');

CREATE INDEX idx_product_enrichment_diskann
ON public.product_catalog_enrichment_output
USING diskann (embedding vector_cosine_ops)
WHERE embedding IS NOT NULL;

ANALYZE public.product_catalog_enrichment_output;
