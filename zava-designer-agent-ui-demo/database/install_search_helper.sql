\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS zava_ai AUTHORIZATION CURRENT_USER;

CREATE OR REPLACE FUNCTION zava_ai.search(
    query            text,
    source_table     text    DEFAULT 'product_metadata_demo',
    search_type      text    DEFAULT 'hybrid',
    top_k            int     DEFAULT 10,
    rrf_k            int     DEFAULT 60,
    content_column   text    DEFAULT NULL,
    embedding_column text    DEFAULT NULL,
    id_column        text    DEFAULT NULL,
    title_column     text    DEFAULT NULL,
    embedding_model  text    DEFAULT 'text-embedding-3-small',
    rerank_model     text    DEFAULT 'gpt-4.1',
    rerank           boolean DEFAULT false,
    filter           text    DEFAULT NULL
)
RETURNS TABLE (
    id         int,
    title      text,
    content    text,
    score      real,
    match_type text
)
LANGUAGE plpgsql
VOLATILE
SET search_path = public, "$user"
AS $$
DECLARE
    query_embedding vector(1536);
    fetch_limit int := CASE WHEN rerank THEN top_k * 3 ELSE top_k END;
    filter_clause text := CASE
        WHEN filter IS NULL THEN ''
        ELSE ' AND (' || filter || ')'
    END;
BEGIN
    IF source_table <> 'product_metadata_demo' THEN
        RAISE EXCEPTION 'zava_ai.search only supports product_metadata_demo';
    END IF;

    IF search_type NOT IN ('hybrid', 'vector', 'fulltext') THEN
        RAISE EXCEPTION 'Unknown search_type: %', search_type;
    END IF;

    CREATE TEMP TABLE IF NOT EXISTS zava_search_candidates (
        candidate_id int,
        candidate_title text,
        candidate_content text,
        candidate_score real,
        candidate_match_type text
    ) ON COMMIT DROP;
    TRUNCATE zava_search_candidates;

    IF search_type IN ('hybrid', 'vector') THEN
        query_embedding :=
            azure_openai.create_embeddings(embedding_model, query)::vector;
    END IF;

    IF search_type = 'vector' THEN
        EXECUTE
            'INSERT INTO zava_search_candidates
             SELECT id, title, content,
                    (1 - (embedding <=> $1))::real, ''vector''
             FROM product_metadata_demo
             WHERE embedding IS NOT NULL' || filter_clause || '
             ORDER BY embedding <=> $1
             LIMIT $2'
        USING query_embedding, fetch_limit;
    ELSIF search_type = 'fulltext' THEN
        EXECUTE
            'INSERT INTO zava_search_candidates
             SELECT ranked.id, ranked.title, ranked.content,
                    (-ranked.bm25_distance)::real, ''fulltext''
             FROM (
                 SELECT id, title, content,
                        content <@> to_bm25query($1, ''idx_product_bm25'')
                            AS bm25_distance
                 FROM product_metadata_demo
                 WHERE true' || filter_clause || '
                 ORDER BY content <@> to_bm25query($1, ''idx_product_bm25'')
                 LIMIT $2
             ) ranked
             ORDER BY ranked.bm25_distance'
        USING query, fetch_limit;
    ELSE
        CREATE TEMP TABLE IF NOT EXISTS zava_fulltext_ranked (
            document_id int,
            document_rank int
        ) ON COMMIT DROP;
        TRUNCATE zava_fulltext_ranked;

        EXECUTE
            'INSERT INTO zava_fulltext_ranked
             SELECT id,
                    ROW_NUMBER() OVER (
                        ORDER BY content <@> to_bm25query($1, ''idx_product_bm25'')
                    )::int
             FROM product_metadata_demo
             WHERE true' || filter_clause || '
             ORDER BY content <@> to_bm25query($1, ''idx_product_bm25'')
             LIMIT $2'
        USING query, fetch_limit;

        EXECUTE
            'INSERT INTO zava_search_candidates
             WITH vector_ranked AS (
                 SELECT id,
                        ROW_NUMBER() OVER (ORDER BY embedding <=> $1)::int AS rank
                 FROM product_metadata_demo
                 WHERE embedding IS NOT NULL' || filter_clause || '
                 ORDER BY embedding <=> $1
                 LIMIT $2
             ),
             all_documents AS (
                 SELECT id FROM vector_ranked
                 UNION
                 SELECT document_id FROM zava_fulltext_ranked
             ),
             rrf_scores AS (
                 SELECT documents.id,
                        (COALESCE(1.0 / ($3 + vectors.rank), 0) +
                         COALESCE(1.0 / ($3 + fulltext.document_rank), 0))::real
                            AS fused_score
                 FROM all_documents documents
                 LEFT JOIN vector_ranked vectors USING (id)
                 LEFT JOIN zava_fulltext_ranked fulltext
                     ON fulltext.document_id = documents.id
             )
             SELECT products.id, products.title, products.content,
                    scores.fused_score, ''hybrid''
             FROM rrf_scores scores
             JOIN product_metadata_demo products ON products.id = scores.id
             ORDER BY scores.fused_score DESC
             LIMIT $2'
        USING query_embedding, fetch_limit, rrf_k;
    END IF;

    IF rerank THEN
        RETURN QUERY
        SELECT candidates.candidate_id,
               candidates.candidate_title,
               candidates.candidate_content,
               ranked.score::real,
               candidates.candidate_match_type
        FROM zava_search_candidates candidates
        JOIN azure_ai.rank(
            query,
            (SELECT array_agg(candidate_content ORDER BY candidate_score DESC)
             FROM zava_search_candidates),
            (SELECT array_agg(candidate_id::text ORDER BY candidate_score DESC)
             FROM zava_search_candidates),
            rerank_model
        ) ranked ON ranked.id = candidates.candidate_id::text
        ORDER BY ranked.score DESC
        LIMIT top_k;
    ELSE
        RETURN QUERY
        SELECT candidate_id, candidate_title, candidate_content,
               candidate_score, candidate_match_type
        FROM zava_search_candidates
        ORDER BY candidate_score DESC
        LIMIT top_k;
    END IF;
END;
$$;

COMMENT ON FUNCTION zava_ai.search(
    text, text, text, int, int, text, text, text, text, text, text, boolean, text
) IS
'Zava demo compatibility helper combining pg_textsearch BM25 and pg_diskann vector search with RRF. It is application SQL, not a built-in HorizonDB function.';
