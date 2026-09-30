\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS azure_ai;

CREATE SCHEMA IF NOT EXISTS zava_ai AUTHORIZATION CURRENT_USER;

ALTER TABLE public.product_metadata_demo
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION zava_ai.build_product_search_content(
    product_title text,
    product_description jsonb,
    product_features jsonb,
    product_categories jsonb,
    product_store text,
    product_details jsonb
)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT concat_ws(
        E'\n',
        NULLIF(btrim(product_title), ''),
        NULLIF(product_description::text, 'null'),
        NULLIF(product_features::text, 'null'),
        NULLIF(product_categories::text, 'null'),
        NULLIF(btrim(product_store), ''),
        NULLIF(product_details::text, 'null')
    );
$$;

CREATE OR REPLACE FUNCTION zava_ai.refresh_product_enrichment_source()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.content := zava_ai.build_product_search_content(
        NEW.title,
        NEW.description,
        NEW.features,
        NEW.categories,
        NEW.store,
        NEW.details
    );
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS product_metadata_demo_enrichment_source_trg
    ON public.product_metadata_demo;

CREATE TRIGGER product_metadata_demo_enrichment_source_trg
BEFORE INSERT OR UPDATE OF
    title, description, features, categories, store, details
ON public.product_metadata_demo
FOR EACH ROW
EXECUTE FUNCTION zava_ai.refresh_product_enrichment_source();

UPDATE public.product_metadata_demo
SET content = zava_ai.build_product_search_content(
        title,
        description,
        features,
        categories,
        store,
        details
    ),
    updated_at = clock_timestamp();

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM ai.list_pipelines()
        WHERE name = 'product_catalog_enrichment'
    ) THEN
        PERFORM ai.drop_pipeline('product_catalog_enrichment');
    END IF;
END;
$$;

DROP VIEW IF EXISTS public.product_catalog_enriched;
DROP TABLE IF EXISTS public.product_catalog_enrichment_output CASCADE;

CREATE TABLE public.product_catalog_enrichment_output (
    doc_id integer NOT NULL,
    chunk_index integer NOT NULL,
    chunk_text text NOT NULL,
    embedding vector(1536),
    metadata jsonb,
    PRIMARY KEY (doc_id, chunk_index)
);

SELECT ai.create_pipeline(
    name => 'product_catalog_enrichment',
    source => ai.table_source(
        table_name => 'product_metadata_demo',
        incremental_column => 'updated_at',
        schema_name => 'public'
    ),
    steps => ARRAY[
        ai.chunk(
            input => 'content',
            chunk_size => 4096,
            overlap => 0
        ),
        ai.embed(
            model => 'default-embedding',
            input_column => 'chunk_text',
            dimensions => 1536,
            batch_size => 25
        ),
        ai.extract(
            model => 'default-chat',
            input_column => 'chunk_text',
            data => ARRAY[
                'design_style: string - one of Mid-Century Modern, Industrial, Scandinavian, Bohemian, Farmhouse, Minimalist, Contemporary, Traditional, or Unknown',
                'material: string - primary product material, or Unknown',
                'color: string - primary product color, or Unknown',
                'room_category: string - one of Seating, Tables, Lighting, Rugs, Storage, Decor, or Unknown',
                'product_traits: string - comma-separated functional or visual traits, or Unknown'
            ]
        )
    ],
    sink => ai.table_sink(
        table_name => 'product_catalog_enrichment_output',
        schema_name => 'public',
        on_conflict => ARRAY['doc_id', 'chunk_index'],
        on_conflict_action =>
            'DO UPDATE SET chunk_text = EXCLUDED.chunk_text, embedding = EXCLUDED.embedding, metadata = EXCLUDED.metadata'
    ),
    trigger => 'on_change'
);

CREATE VIEW public.product_catalog_enriched AS
WITH output_stats AS (
    SELECT
        doc_id,
        count(*)::integer AS enrichment_chunk_count,
        bool_and(embedding IS NOT NULL) AS all_chunks_have_embeddings,
        bool_and(
            embedding IS NULL OR vector_dims(embedding) = 1536
        ) AS embedding_dimensions_valid
    FROM public.product_catalog_enrichment_output
    GROUP BY doc_id
),
first_chunk AS (
    SELECT DISTINCT ON (doc_id)
        doc_id,
        metadata
    FROM public.product_catalog_enrichment_output
    ORDER BY doc_id, chunk_index
),
enrichment AS (
    SELECT
        products.*,
        stats.enrichment_chunk_count,
        first_chunk.metadata AS enrichment_metadata,
        NULLIF(btrim(first_chunk.metadata->>'design_style'), '') AS design_style,
        NULLIF(btrim(first_chunk.metadata->>'material'), '') AS material,
        NULLIF(btrim(first_chunk.metadata->>'color'), '') AS color,
        NULLIF(btrim(first_chunk.metadata->>'room_category'), '') AS room_category,
        NULLIF(btrim(first_chunk.metadata->>'product_traits'), '') AS product_traits,
        to_jsonb(array_remove(ARRAY[
            CASE WHEN NULLIF(btrim(products.title), '') IS NULL
                THEN 'missing_title' END,
            CASE WHEN NULLIF(btrim(products.content), '') IS NULL
                THEN 'missing_search_content' END,
            CASE WHEN stats.doc_id IS NULL
                THEN 'missing_pipeline_output' END,
            CASE WHEN NOT COALESCE(stats.all_chunks_have_embeddings, false)
                THEN 'missing_embedding' END,
            CASE WHEN NOT COALESCE(stats.embedding_dimensions_valid, false)
                THEN 'invalid_embedding_dimensions' END,
            CASE WHEN NULLIF(btrim(first_chunk.metadata->>'design_style'), '') IS NULL
                THEN 'missing_design_style' END,
            CASE WHEN NULLIF(btrim(first_chunk.metadata->>'material'), '') IS NULL
                THEN 'missing_material' END,
            CASE WHEN NULLIF(btrim(first_chunk.metadata->>'color'), '') IS NULL
                THEN 'missing_color' END,
            CASE WHEN NULLIF(btrim(first_chunk.metadata->>'room_category'), '') IS NULL
                THEN 'missing_room_category' END
        ], NULL)) AS quality_flags
    FROM public.product_metadata_demo AS products
    LEFT JOIN output_stats AS stats ON stats.doc_id = products.id
    LEFT JOIN first_chunk ON first_chunk.doc_id = products.id
)
SELECT
    enrichment.*,
    jsonb_array_length(enrichment.quality_flags) = 0 AS enrichment_ready
FROM enrichment;

COMMENT ON TABLE public.product_catalog_enrichment_output IS
    'Derived, rebuildable chunk embeddings and structured attributes for the Zava product catalog.';
COMMENT ON VIEW public.product_catalog_enriched IS
    'Product-level Zava catalog projection with normalized enrichment attributes, quality flags, and readiness.';

SELECT ai.run('product_catalog_enrichment');
