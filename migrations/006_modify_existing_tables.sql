-- Migration 006: Modify Existing Tables
-- Purpose: Update existing tables to match new schema requirements

-- Modify creators table
ALTER TABLE public.creators 
    ADD COLUMN IF NOT EXISTS user_id text,
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

-- Add foreign key to users table
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'creators_user_id_fkey' 
        AND conrelid = 'public.creators'::regclass
    ) THEN
        ALTER TABLE public.creators 
        ADD CONSTRAINT creators_user_id_fkey 
        FOREIGN KEY (user_id) REFERENCES public.users(id);
    END IF;
END $$;

-- Modify ads table
-- Add new columns
ALTER TABLE public.ads
    ADD COLUMN IF NOT EXISTS placement public.ad_placement DEFAULT 'default',
    ADD COLUMN IF NOT EXISTS bid_amount numeric(14,6),
    ADD COLUMN IF NOT EXISTS target_url text,
    ADD COLUMN IF NOT EXISTS content text;

-- Create aliases for renamed columns (if they don't exist)
DO $$
BEGIN
    -- If 'url' exists but 'target_url' doesn't, rename it
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'ads' AND column_name = 'url'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'ads' AND column_name = 'target_url'
    ) THEN
        ALTER TABLE public.ads RENAME COLUMN url TO target_url;
    END IF;
    
    -- If 'description' exists but 'content' doesn't, rename it
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'ads' AND column_name = 'description'
    ) AND NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'ads' AND column_name = 'content'
    ) THEN
        ALTER TABLE public.ads RENAME COLUMN description TO content;
    END IF;
END $$;

-- Convert embedding column from vector to text
ALTER TABLE public.ads 
    ALTER COLUMN embedding TYPE text 
    USING embedding::text;

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

-- Convert chat_messages embedding to text
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'chat_messages' 
        AND column_name = 'embedding'
        AND udt_name = 'vector'
    ) THEN
        ALTER TABLE public.chat_messages 
            ALTER COLUMN embedding TYPE text 
            USING embedding::text;
    END IF;
END $$;

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
CREATE INDEX IF NOT EXISTS idx_creators_user_id ON public.creators(user_id);
CREATE INDEX IF NOT EXISTS idx_creators_approval_status ON public.creators(approval_status);
CREATE INDEX IF NOT EXISTS idx_ads_placement ON public.ads(placement);
CREATE INDEX IF NOT EXISTS idx_ad_impressions_mcp_tool_call_id ON public.ad_impressions(mcp_tool_call_id);

-- Add comments for new columns
COMMENT ON COLUMN public.creators.user_id IS 'Link to Frontend Auth user';
COMMENT ON COLUMN public.creators.approval_status IS 'Creator approval workflow status';
COMMENT ON COLUMN public.creators.permissions IS 'JSON array of creator permissions';
COMMENT ON COLUMN public.ads.placement IS 'Where the ad should be displayed';
COMMENT ON COLUMN public.ads.bid_amount IS 'Bid amount for competitive ad placement';
COMMENT ON COLUMN public.chat_messages.role IS 'Message sender role: user, assistant, or system';
COMMENT ON COLUMN public.ad_impressions.mcp_tool_call_id IS 'MCP tool call tracking ID';