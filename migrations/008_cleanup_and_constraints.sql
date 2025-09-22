-- Migration 008: Cleanup and Final Constraints
-- Purpose: Add final constraints and cleanup after data migration

-- Ensure NOT NULL constraints on migrated columns
-- Only add if majority of rows have values
DO $$
DECLARE
    null_count integer;
    total_count integer;
BEGIN
    -- Check creators.email
    SELECT COUNT(*) FILTER (WHERE email IS NULL), COUNT(*) 
    INTO null_count, total_count
    FROM public.creators;
    
    IF null_count = 0 AND total_count > 0 THEN
        ALTER TABLE public.creators ALTER COLUMN email SET NOT NULL;
    END IF;
    
    -- Check chat_messages.content
    SELECT COUNT(*) FILTER (WHERE content IS NULL), COUNT(*)
    INTO null_count, total_count  
    FROM public.chat_messages;
    
    IF null_count = 0 AND total_count > 0 THEN
        ALTER TABLE public.chat_messages ALTER COLUMN content SET NOT NULL;
    END IF;
    
    -- Check chat_messages.role
    SELECT COUNT(*) FILTER (WHERE role IS NULL), COUNT(*)
    INTO null_count, total_count
    FROM public.chat_messages;
    
    IF null_count = 0 AND total_count > 0 THEN
        ALTER TABLE public.chat_messages ALTER COLUMN role SET NOT NULL;
    END IF;
END $$;

-- Add missing foreign key constraints
DO $$
BEGIN
    -- Add foreign key from ad_impressions to ads if missing
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint 
        WHERE conname = 'ad_impressions_ad_id_fkey'
    ) THEN
        ALTER TABLE public.ad_impressions
        ADD CONSTRAINT ad_impressions_ad_id_fkey
        FOREIGN KEY (ad_id) REFERENCES public.ads(id);
    END IF;
    
    -- Add foreign key from ad_impressions to creators if missing
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'ad_impressions_creator_id_fkey'
    ) THEN
        ALTER TABLE public.ad_impressions
        ADD CONSTRAINT ad_impressions_creator_id_fkey
        FOREIGN KEY (creator_id) REFERENCES public.creators(id);
    END IF;
END $$;

-- Create views for backwards compatibility
CREATE OR REPLACE VIEW public.v_users_with_creators AS
SELECT 
    au.id as user_id,
    au.email,
    au.name as user_name,
    au.picture,
    au.email_verified,
    au.provider,
    c.id as creator_id,
    c.name as creator_name,
    c.bio,
    c.is_active,
    c.approval_status,
    c.approval_date,
    c.permissions,
    c.user_id as legacy_user_id
FROM public.auth_users au
LEFT JOIN public.creators c ON c.auth_user_id = au.id;

-- Create view for active campaigns with ads
CREATE OR REPLACE VIEW public.v_active_campaigns_ads AS
SELECT 
    ac.id as campaign_id,
    ac.name as campaign_name,
    ac.advertiser_id,
    ac.budget_amount,
    ac.spent_amount,
    ac.start_date,
    ac.end_date,
    ac.status as campaign_status,
    a.id as ad_id,
    a.title,
    a.content,
    a.target_url,
    a.ad_type,
    a.placement,
    a.pricing_model,
    a.status as ad_status
FROM public.ad_campaigns ac
INNER JOIN public.ads a ON a.campaign_id = ac.id
WHERE ac.status = 'active'
AND a.status = 'active'
AND ac.end_date > now()
AND ac.spent_amount < ac.budget_amount;

-- Create indexes for common queries
CREATE INDEX IF NOT EXISTS idx_ads_status_campaign ON public.ads(status, campaign_id);
CREATE INDEX IF NOT EXISTS idx_ad_campaigns_status_dates ON public.ad_campaigns(status, start_date, end_date);
CREATE INDEX IF NOT EXISTS idx_creators_email ON public.creators(email);
CREATE INDEX IF NOT EXISTS idx_api_keys_last_used ON public.api_keys(last_used_at);

-- Add triggers for updated_at columns
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply updated_at trigger to tables that need it
DO $$
DECLARE
    t text;
BEGIN
    -- Handle tables without generated columns
    FOR t IN 
        SELECT unnest(ARRAY[
            'ads', 'creators', 'business_settings',
            'ad_categories', 'advertisers', 'content'
        ])
    LOOP
        BEGIN
            EXECUTE format('
                CREATE TRIGGER set_updated_at_%s
                BEFORE UPDATE ON public.%s
                FOR EACH ROW
                WHEN (OLD.* IS DISTINCT FROM NEW.*)
                EXECUTE FUNCTION trigger_set_updated_at()',
                t, t
            );
        EXCEPTION
            WHEN duplicate_object THEN
                NULL; -- Ignore if trigger already exists
        END;
    END LOOP;
    
    -- Handle ad_campaigns separately (has generated column)
    BEGIN
        CREATE TRIGGER set_updated_at_ad_campaigns
        BEFORE UPDATE ON public.ad_campaigns
        FOR EACH ROW
        -- Don't use WHEN clause for tables with generated columns
        EXECUTE FUNCTION trigger_set_updated_at();
    EXCEPTION
        WHEN duplicate_object THEN
            NULL; -- Ignore if trigger already exists
    END;
END $$;

-- Final statistics and validation
DO $$
DECLARE
    rec record;
BEGIN
    RAISE NOTICE 'Migration Summary:';
    
    FOR rec IN 
        SELECT 
            'auth_users' as table_name, COUNT(*) as row_count 
        FROM public.auth_users
        UNION ALL
        SELECT 'users (legacy)', COUNT(*) FROM public.users
        UNION ALL
        SELECT 'creators', COUNT(*) FROM public.creators
        UNION ALL
        SELECT 'api_keys', COUNT(*) FROM public.api_keys
        UNION ALL
        SELECT 'ads', COUNT(*) FROM public.ads
        UNION ALL
        SELECT 'ad_campaigns', COUNT(*) FROM public.ad_campaigns
        UNION ALL
        SELECT 'agreement_versions', COUNT(*) FROM public.agreement_versions
    LOOP
        RAISE NOTICE '  %: % rows', rec.table_name, rec.row_count;
    END LOOP;
END $$;

-- Grant appropriate permissions (adjust based on your database users)
-- GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO your_app_user;
-- GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO your_app_user;

COMMENT ON VIEW public.v_users_with_creators IS 'Combined view of users and their creator profiles';
COMMENT ON VIEW public.v_active_campaigns_ads IS 'Active campaigns with their associated active ads';