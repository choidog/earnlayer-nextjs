-- Migration 010: Fix Remaining Issues
-- Purpose: Address any remaining schema mismatches after initial migrations

-- 1. Fix creators table - ensure auth_user_id index exists
CREATE INDEX IF NOT EXISTS idx_creators_email ON public.creators(email);

-- 2. Ensure effective_cpc_rates table exists (UNLOGGED for performance)
CREATE UNLOGGED TABLE IF NOT EXISTS public.effective_cpc_rates (
    creator_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    placement public.ad_placement NOT NULL,
    ad_type public.ad_type NOT NULL,
    effective_cpc_rate public.money_amount NOT NULL
);

-- Add primary key if not exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'effective_cpc_rates_pkey'
    ) THEN
        ALTER TABLE public.effective_cpc_rates 
        ADD CONSTRAINT effective_cpc_rates_pkey 
        PRIMARY KEY (creator_id, campaign_id, placement, ad_type);
    END IF;
END $$;

-- 3. Create a view to map auth_users to the expected "users" interface
-- This helps if code expects a "users" table with text IDs
CREATE OR REPLACE VIEW public.v_users AS
SELECT 
    id,
    email,
    name,
    picture,
    email_verified,
    provider,
    created_at,
    updated_at
FROM public.auth_users;

COMMENT ON VIEW public.v_users IS 'Compatibility view mapping auth_users to users interface';

-- 4. Ensure all required indexes exist
CREATE INDEX IF NOT EXISTS idx_ad_campaigns_status ON public.ad_campaigns(status);
CREATE INDEX IF NOT EXISTS idx_ads_campaign_id_status ON public.ads(campaign_id, status);
CREATE INDEX IF NOT EXISTS idx_ads_ad_type ON public.ads(ad_type);
CREATE INDEX IF NOT EXISTS idx_ad_impressions_created_at ON public.ad_impressions(created_at);
CREATE INDEX IF NOT EXISTS idx_chat_sessions_creator_id ON public.chat_sessions(creator_id);
CREATE INDEX IF NOT EXISTS idx_chat_messages_session_id ON public.chat_messages(session_id);

-- 5. Ensure proper constraints on business_settings
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'business_settings_creator_id_key'
    ) THEN
        ALTER TABLE public.business_settings 
        ADD CONSTRAINT business_settings_creator_id_key UNIQUE (creator_id);
    END IF;
END $$;

-- 6. Add missing columns to ads table if they don't exist
ALTER TABLE public.ads
    ADD COLUMN IF NOT EXISTS image_url varchar(255),
    ADD COLUMN IF NOT EXISTS needs_description boolean DEFAULT false NOT NULL,
    ADD COLUMN IF NOT EXISTS estimated_epc numeric(14,6) DEFAULT 0.00;

-- 7. Refresh effective CPC rates if the function exists
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_proc 
        WHERE proname = 'refresh_effective_cpc_rates'
    ) THEN
        PERFORM refresh_effective_cpc_rates();
    END IF;
END $$;

-- 8. Create missing sequences if needed
CREATE SEQUENCE IF NOT EXISTS public.api_logs_id_seq;

-- Set ownership if the sequence was just created
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_class 
        WHERE relname = 'api_logs_id_seq'
    ) THEN
        ALTER SEQUENCE public.api_logs_id_seq OWNED BY public.api_logs.id;
    END IF;
END $$;

-- 9. Summary of user tables situation
DO $$
BEGIN
    RAISE NOTICE 'User Tables Summary:';
    RAISE NOTICE '  - users (legacy): UUID-based, original password auth';
    RAISE NOTICE '  - auth_users: Text-based IDs for OAuth/Better Auth';
    RAISE NOTICE '  - "user": Better Auth compatibility table';
    RAISE NOTICE '  - creators.user_id: Links to legacy users (UUID)';
    RAISE NOTICE '  - creators.auth_user_id: Links to auth_users (text)';
    RAISE NOTICE '';
    RAISE NOTICE 'The application should use auth_users for all new auth operations.';
END $$;

-- 10. Final check for critical tables
DO $$
DECLARE
    missing_tables text[] := '{}';
    t text;
BEGIN
    -- Check for critical tables
    FOR t IN VALUES 
        ('embeddings'), ('ad_queue'), ('advertiser_payments'), 
        ('creator_affiliate_codes'), ('effective_cpc_rates')
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM information_schema.tables 
            WHERE table_schema = 'public' 
            AND table_name = t
        ) THEN
            missing_tables := array_append(missing_tables, t);
        END IF;
    END LOOP;
    
    IF array_length(missing_tables, 1) > 0 THEN
        RAISE WARNING 'Missing critical tables: %', missing_tables;
    ELSE
        RAISE NOTICE 'All critical tables are present.';
    END IF;
END $$;