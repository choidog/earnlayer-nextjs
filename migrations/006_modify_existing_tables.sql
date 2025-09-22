-- Migration 006: Modify Existing Tables
-- Purpose: Update existing tables to match new schema requirements

-- Modify creators table
-- The user_id column already exists as UUID type, we need to add a new column for auth linkage
ALTER TABLE public.creators 
    ADD COLUMN IF NOT EXISTS auth_user_id text,
    ADD COLUMN IF NOT EXISTS email varchar(255),
    ADD COLUMN IF NOT EXISTS approval_status varchar(20) DEFAULT 'pending',
    ADD COLUMN IF NOT EXISTS approval_date timestamp with time zone,
    ADD COLUMN IF NOT EXISTS rejection_reason text,
    ADD COLUMN IF NOT EXISTS permissions jsonb DEFAULT '[]',
    ADD COLUMN IF NOT EXISTS last_approval_check timestamp with time zone DEFAULT now();

-- Add unique constraint for email if not exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'creators_email_unique' 
        AND conrelid = 'public.creators'::regclass
    ) THEN
        ALTER TABLE public.creators 
        ADD CONSTRAINT creators_email_unique UNIQUE (email);
    END IF;
END $$;

-- Add foreign key to auth_users table using the new column
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'creators_auth_user_id_fkey' 
        AND conrelid = 'public.creators'::regclass
    ) THEN
        ALTER TABLE public.creators 
        ADD CONSTRAINT creators_auth_user_id_fkey 
        FOREIGN KEY (auth_user_id) REFERENCES public.auth_users(id);
    END IF;
END $$;

-- Modify ads table
-- Add new columns that exist in new schema but not in old
ALTER TABLE public.ads
    ADD COLUMN IF NOT EXISTS placement public.ad_placement DEFAULT 'default',
    ADD COLUMN IF NOT EXISTS bid_amount numeric(14,6),
    ADD COLUMN IF NOT EXISTS target_url varchar(255),
    ADD COLUMN IF NOT EXISTS content text;

-- Handle column mappings without breaking existing data
DO $$
BEGIN
    -- Copy url to target_url if target_url is empty
    UPDATE public.ads 
    SET target_url = url 
    WHERE target_url IS NULL AND url IS NOT NULL;
    
    -- Copy description to content if content is empty
    UPDATE public.ads 
    SET content = description 
    WHERE content IS NULL AND description IS NOT NULL;
END $$;

-- IMPORTANT: DO NOT convert embeddings to text - keep vector type!
-- The old system uses embeddings table with proper vector type for similarity search

-- Add embedding column to ads table if needed (for compatibility with new schema)
-- But keep it as text for now since the actual vectors are in embeddings table
ALTER TABLE public.ads
    ADD COLUMN IF NOT EXISTS embedding text;

-- Modify chat_messages table
ALTER TABLE public.chat_messages
    ADD COLUMN IF NOT EXISTS content text,
    ADD COLUMN IF NOT EXISTS role varchar(20);

-- Handle column renames for chat_messages
DO $$
BEGIN
    -- If 'message' exists but 'content' doesn't, rename it
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'chat_messages' AND column_name = 'message'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'chat_messages' AND column_name = 'content'
    ) THEN
        ALTER TABLE public.chat_messages RENAME COLUMN message TO content;
    END IF;
    
    -- If 'is_user' exists, convert to role
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'chat_messages' AND column_name = 'is_user'
    ) THEN
        -- Update existing data
        UPDATE public.chat_messages 
        SET role = CASE 
            WHEN is_user = true THEN 'user'
            ELSE 'assistant'
        END
        WHERE role IS NULL;
        
        -- Drop the old column
        ALTER TABLE public.chat_messages DROP COLUMN is_user;
    END IF;
END $$;

-- DO NOT convert chat_messages embedding to text
-- Keep the embeddings table structure intact for vector searches

-- Modify ad_impressions table
ALTER TABLE public.ad_impressions
    ADD COLUMN IF NOT EXISTS mcp_tool_call_id uuid;

-- Modify business_settings table
ALTER TABLE public.business_settings
    ALTER COLUMN min_seconds_between_display_ads TYPE numeric 
    USING min_seconds_between_display_ads::numeric;

-- Add check constraints for role values
ALTER TABLE public.chat_messages 
    ADD CONSTRAINT check_chat_messages_role 
    CHECK (role IN ('user', 'assistant', 'system'));

-- Add indexes for new columns
CREATE INDEX IF NOT EXISTS idx_creators_auth_user_id ON public.creators(auth_user_id);
CREATE INDEX IF NOT EXISTS idx_creators_approval_status ON public.creators(approval_status);
CREATE INDEX IF NOT EXISTS idx_ads_placement ON public.ads(placement);
CREATE INDEX IF NOT EXISTS idx_ad_impressions_mcp_tool_call_id ON public.ad_impressions(mcp_tool_call_id);

-- Add comments for new columns
COMMENT ON COLUMN public.creators.auth_user_id IS 'Link to Frontend Auth user (text ID)';
COMMENT ON COLUMN public.creators.user_id IS 'Legacy link to original users table (UUID)';
COMMENT ON COLUMN public.creators.approval_status IS 'Creator approval workflow status';
COMMENT ON COLUMN public.creators.permissions IS 'JSON array of creator permissions';
COMMENT ON COLUMN public.ads.placement IS 'Where the ad should be displayed';
COMMENT ON COLUMN public.ads.bid_amount IS 'Bid amount for competitive ad placement';
COMMENT ON COLUMN public.chat_messages.role IS 'Message sender role: user, assistant, or system';
COMMENT ON COLUMN public.ad_impressions.mcp_tool_call_id IS 'MCP tool call tracking ID';