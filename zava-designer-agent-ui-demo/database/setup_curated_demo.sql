\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
CREATE EXTENSION IF NOT EXISTS pg_diskann;
CREATE EXTENSION IF NOT EXISTS azure_ai;

SET search_path = public, "$user";

DROP TABLE IF EXISTS public.product_metadata_demo CASCADE;

CREATE TABLE public.product_metadata_demo (
    id integer PRIMARY KEY,
    parent_asin text,
    title text,
    average_rating real,
    rating_number integer,
    features jsonb,
    description jsonb,
    price numeric(10, 2),
    images jsonb,
    store text,
    categories jsonb,
    details jsonb,
    embedding vector(1536),
    price_num numeric(10, 2),
    category text,
    content text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.product_metadata_demo IS
    'Curated Home and Kitchen products for the Zava Designer Agent demo.';
COMMENT ON COLUMN public.product_metadata_demo.title IS
    'Customer-facing product name used for keyword and semantic retrieval.';
COMMENT ON COLUMN public.product_metadata_demo.content IS
    'Searchable product text combining title, description, features, and category context.';
COMMENT ON COLUMN public.product_metadata_demo.embedding IS
    '1536-dimensional product embedding used for semantic and hybrid search.';
COMMENT ON COLUMN public.product_metadata_demo.categories IS
    'Amazon-style category hierarchy used to constrain room-design searches.';
COMMENT ON COLUMN public.product_metadata_demo.price_num IS
    'Normalized numeric price used by the budget filter.';
COMMENT ON COLUMN public.product_metadata_demo.updated_at IS
    'Change watermark used by the product catalog enrichment pipeline.';

CREATE TABLE IF NOT EXISTS public.semantic_dictionary (
    term text PRIMARY KEY,
    canonical text NOT NULL,
    context text,
    notes text
);

TRUNCATE public.semantic_dictionary;

INSERT INTO public.semantic_dictionary (term, canonical, context, notes) VALUES
    ('mid-century', 'mid-century modern', 'interior design style', 'Warm wood, clean lines, and tapered legs'),
    ('brooklyn loft', 'industrial loft', 'room architecture', 'Brick, metal, hardwood, and open-plan context'),
    ('reading light', 'floor lamp', 'lighting', 'Task lighting for a seating area'),
    ('accent seating', 'accent chair', 'furniture', 'Single statement chair for living rooms'),
    ('storage', 'bookcase shelving unit', 'furniture', 'Open vertical storage suitable for a loft'),
    ('wall decor', 'wall art print painting', 'decor', 'Artwork for exposed-brick or neutral walls'),
    ('area carpet', 'area rug', 'flooring', 'Soft floor covering that anchors a seating group')
ON CONFLICT (term) DO UPDATE
SET canonical = EXCLUDED.canonical,
    context = EXCLUDED.context,
    notes = EXCLUDED.notes;
