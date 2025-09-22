-- Migration 009: Handle Embeddings Compatibility
-- Purpose: Ensure embeddings work with both old and new code

-- The embeddings table already exists and contains vector data
-- We need to ensure it remains intact for vector searches

-- Create a view to provide compatibility with code expecting embeddings in ads table
CREATE OR REPLACE VIEW public.v_ads_with_embeddings AS
SELECT 
    a.*,
    e.embedding::text as embedding_text,
    e.embedding as embedding_vector
FROM public.ads a
LEFT JOIN public.embeddings e ON 
    e.source_id = a.id AND 
    e.source_table = 'ads' AND
    e.chunk_id = 0;

-- Create a function to sync embeddings from ads.embedding text field to embeddings table
-- This is only needed if new code writes embeddings to ads.embedding as text
CREATE OR REPLACE FUNCTION sync_ad_embedding_to_table()
RETURNS TRIGGER AS $$
DECLARE
    embedding_array float[];
BEGIN
    -- Only process if embedding changed and is not null
    IF NEW.embedding IS DISTINCT FROM OLD.embedding AND NEW.embedding IS NOT NULL THEN
        -- Try to parse the text as an array
        BEGIN
            -- Handle different text formats
            IF NEW.embedding LIKE '[%]' THEN
                -- JSON array format: [0.1, 0.2, ...]
                embedding_array := ARRAY(
                    SELECT unnest(string_to_array(
                        regexp_replace(NEW.embedding, '[\[\]]', '', 'g'), 
                        ','
                    )::float[])
                );
            ELSIF NEW.embedding LIKE '{%}' THEN
                -- PostgreSQL array format: {0.1,0.2,...}
                embedding_array := NEW.embedding::float[];
            END IF;
            
            -- Insert or update in embeddings table
            INSERT INTO public.embeddings (source_table, source_id, embedding, chunk_id)
            VALUES ('ads', NEW.id, embedding_array::vector, 0)
            ON CONFLICT (source_table, source_id, chunk_id) 
            DO UPDATE SET 
                embedding = EXCLUDED.embedding,
                created_at = now();
                
        EXCEPTION WHEN OTHERS THEN
            -- Log error but don't fail the transaction
            RAISE WARNING 'Could not parse embedding for ad %: %', NEW.id, SQLERRM;
        END;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Only create trigger if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger 
        WHERE tgname = 'sync_ad_embedding_trigger'
    ) THEN
        CREATE TRIGGER sync_ad_embedding_trigger
        AFTER INSERT OR UPDATE ON public.ads
        FOR EACH ROW
        EXECUTE FUNCTION sync_ad_embedding_to_table();
    END IF;
END $$;

-- Ensure embeddings table has proper indexes (if not already present)
DO $$
BEGIN
    -- Check if ivfflat index exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE indexname = 'idx_embeddings_ann'
    ) THEN
        -- Create index for cosine similarity
        CREATE INDEX idx_embeddings_ann 
        ON public.embeddings 
        USING ivfflat (embedding vector_cosine_ops) 
        WITH (lists = 100);
    END IF;
    
    -- Check if regular ivfflat index exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE indexname = 'idx_embeddings_embedding'
    ) THEN
        CREATE INDEX idx_embeddings_embedding 
        ON public.embeddings 
        USING ivfflat (embedding) 
        WITH (lists = 100);
    END IF;
    
    -- Create composite index for lookups
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes 
        WHERE indexname = 'idx_embeddings_source'
    ) THEN
        CREATE INDEX idx_embeddings_source 
        ON public.embeddings(source_table, source_id, chunk_id);
    END IF;
END $$;

-- Add unique constraint to prevent duplicate embeddings
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'embeddings_source_unique'
    ) THEN
        ALTER TABLE public.embeddings
        ADD CONSTRAINT embeddings_source_unique 
        UNIQUE (source_table, source_id, chunk_id);
    END IF;
END $$;

-- Populate ads.embedding text field from embeddings table for compatibility
-- This helps new code that expects embeddings in ads table
UPDATE public.ads a
SET embedding = e.embedding::text
FROM public.embeddings e
WHERE e.source_id = a.id 
    AND e.source_table = 'ads' 
    AND e.chunk_id = 0
    AND a.embedding IS NULL;

-- Add comment
COMMENT ON VIEW public.v_ads_with_embeddings IS 'Compatibility view showing ads with their embeddings from embeddings table';
COMMENT ON FUNCTION sync_ad_embedding_to_table() IS 'Syncs text embeddings from ads table to proper vector format in embeddings table';
COMMENT ON TABLE public.embeddings IS 'Stores vector embeddings for ads and content - DO NOT DROP, required for similarity search';