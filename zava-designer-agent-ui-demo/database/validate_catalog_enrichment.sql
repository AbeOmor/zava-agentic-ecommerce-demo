\set ON_ERROR_STOP on

DO $$
DECLARE
    pipeline_status text;
    source_count bigint;
    enriched_count bigint;
    invalid_count bigint;
BEGIN
    SELECT lower(status)
    INTO pipeline_status
    FROM ai.result('product_catalog_enrichment')
    ORDER BY started_at DESC
    LIMIT 1;

    IF pipeline_status IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION
            'product_catalog_enrichment is not complete; latest status: %',
            COALESCE(pipeline_status, '<missing>');
    END IF;

    SELECT count(*) INTO source_count
    FROM public.product_metadata_demo;

    SELECT count(*) INTO enriched_count
    FROM public.product_catalog_enriched
    WHERE enrichment_chunk_count > 0;

    IF enriched_count <> source_count THEN
        RAISE EXCEPTION
            'Enrichment coverage mismatch: % source products, % enriched products',
            source_count,
            enriched_count;
    END IF;

    SELECT count(*) INTO invalid_count
    FROM public.product_catalog_enrichment_output
    WHERE embedding IS NULL
       OR vector_dims(embedding) <> 1536
       OR NULLIF(btrim(chunk_text), '') IS NULL
       OR metadata IS NULL;

    IF invalid_count > 0 THEN
        RAISE EXCEPTION
            'Found % invalid enrichment chunks',
            invalid_count;
    END IF;
END;
$$;

SELECT
    count(*) AS products,
    count(*) FILTER (WHERE enrichment_ready) AS ready_products,
    count(*) FILTER (WHERE NOT enrichment_ready) AS flagged_products
FROM public.product_catalog_enriched;

SELECT quality_flags, count(*)
FROM public.product_catalog_enriched
WHERE NOT enrichment_ready
GROUP BY quality_flags
ORDER BY count(*) DESC, quality_flags;

DO $$
DECLARE
    smoke_id integer;
    previous_updated_at timestamptz;
    changed_updated_at timestamptz;
    latest_status text;
    deadline timestamptz := clock_timestamp() + interval '5 minutes';
BEGIN
    SELECT id, updated_at
    INTO smoke_id, previous_updated_at
    FROM public.product_metadata_demo
    ORDER BY id
    LIMIT 1;

    UPDATE public.product_metadata_demo
    SET title = title
    WHERE id = smoke_id;

    SELECT updated_at
    INTO changed_updated_at
    FROM public.product_metadata_demo
    WHERE id = smoke_id;

    IF changed_updated_at <= previous_updated_at THEN
        RAISE EXCEPTION 'updated_at trigger did not advance for product %', smoke_id;
    END IF;

    LOOP
        SELECT lower(status)
        INTO latest_status
        FROM ai.result('product_catalog_enrichment')
        ORDER BY started_at DESC
        LIMIT 1;

        EXIT WHEN latest_status = 'completed'
            AND EXISTS (
                SELECT 1
                FROM public.product_catalog_enriched
                WHERE id = smoke_id
                  AND enrichment_ready
            );

        IF latest_status = 'failed' THEN
            RAISE EXCEPTION 'On-change enrichment failed for product %', smoke_id;
        END IF;

        IF clock_timestamp() > deadline THEN
            RAISE EXCEPTION
                'Timed out waiting for on-change enrichment for product %; latest status: %',
                smoke_id,
                COALESCE(latest_status, '<missing>');
        END IF;

        PERFORM pg_sleep(1);
    END LOOP;
END;
$$;

SELECT
    search.id,
    search.title,
    search.score,
    enriched.design_style,
    enriched.material,
    enriched.color,
    enriched.room_category,
    enriched.quality_flags
FROM zava_ai.search(
    'mid-century modern living room furniture',
    source_table => 'product_metadata_demo',
    search_type => 'hybrid',
    top_k => 10
) AS search
JOIN public.product_catalog_enriched AS enriched USING (id)
WHERE enriched.enrichment_ready
ORDER BY search.score DESC;
