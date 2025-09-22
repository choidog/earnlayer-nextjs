-- Migration 007: Data Migration and Linking
-- Purpose: Migrate existing data to work with new authentication system

-- Create temporary mapping table for user migration
CREATE TEMPORARY TABLE user_migration_map (
    old_user_id uuid,
    new_user_id text,
    email varchar(255)
);

-- Populate auth_users from existing users table
-- Keep the original users table intact
INSERT INTO public.auth_users (id, email, name, email_verified, created_at, updated_at)
SELECT 
    'legacy_' || u.id::text as id,  -- Prefix legacy users
    u.email,
    COALESCE(c.name, split_part(u.email, '@', 1)) as name,  -- Use creator name or email prefix
    true as email_verified,  -- Assume verified for existing users
    u.created_at,
    u.updated_at
FROM public.users u
LEFT JOIN public.creators c ON c.user_id = u.id
WHERE NOT EXISTS (
    SELECT 1 FROM public.auth_users au 
    WHERE au.email = u.email
)
ON CONFLICT (email) DO NOTHING;

-- Store the mapping
INSERT INTO user_migration_map (old_user_id, new_user_id, email)
SELECT 
    u.id as old_user_id,
    'legacy_' || u.id::text as new_user_id,
    u.email
FROM public.users u;

-- Update creators table to link to new auth users
-- Keep the original user_id intact, add auth_user_id
UPDATE public.creators c
SET 
    auth_user_id = m.new_user_id,
    email = COALESCE(c.email, m.email)
FROM user_migration_map m
WHERE c.user_id = m.old_user_id
AND c.user_id IS NOT NULL;

-- Migrate API keys if they exist in creators or elsewhere
-- This is a placeholder - adjust based on where API keys are currently stored
DO $$
BEGIN
    -- Check if there's an api_key column in creators
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'creators' AND column_name = 'api_key'
    ) THEN
        INSERT INTO public.api_keys (id, name, key, user_id, created_at, updated_at)
        SELECT 
            gen_random_uuid()::text,
            'Legacy API Key' as name,
            c.api_key as key,
            c.auth_user_id, -- Use the new auth_user_id
            c.created_at,
            c.created_at as updated_at
        FROM public.creators c
        WHERE c.api_key IS NOT NULL 
        AND c.auth_user_id IS NOT NULL
        AND NOT EXISTS (
            SELECT 1 FROM public.api_keys ak 
            WHERE ak.key = c.api_key
        );
    END IF;
END $$;

-- Set default values for new fields where needed
UPDATE public.creators
SET 
    approval_status = CASE 
        WHEN is_active = true THEN 'approved'
        ELSE 'pending'
    END,
    approval_date = CASE 
        WHEN is_active = true THEN created_at
        ELSE NULL
    END,
    permissions = '["mcp:access", "ads:read"]'::jsonb
WHERE approval_status IS NULL;

-- Ensure all ads have required fields
UPDATE public.ads
SET 
    placement = COALESCE(placement, 'default'),
    content = COALESCE(content, title || ' - ' || COALESCE(description, '')),
    target_url = COALESCE(target_url, url)
WHERE placement IS NULL OR content IS NULL OR target_url IS NULL;

-- Update chat messages role field
DO $$
BEGIN
    -- Check if is_user column exists
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'chat_messages' 
        AND column_name = 'is_user'
    ) THEN
        -- Convert is_user to role
        UPDATE public.chat_messages
        SET role = 'user'
        WHERE role IS NULL AND is_user = true;

        UPDATE public.chat_messages
        SET role = 'assistant' 
        WHERE role IS NULL AND (is_user = false OR is_user IS NULL);
    ELSE
        -- If is_user doesn't exist, ensure role has default values
        UPDATE public.chat_messages
        SET role = 'assistant'
        WHERE role IS NULL;
    END IF;
END $$;

-- Create default admin user if needed
INSERT INTO public.auth_users (id, email, name, email_verified, provider, created_at, updated_at)
VALUES (
    'admin_default',
    'admin@earnlayer.com',
    'Admin User',
    true,
    'manual',
    now(),
    now()
)
ON CONFLICT (email) DO NOTHING;

-- Add default agreement if none exists
INSERT INTO public.agreement_versions (
    version_string,
    content_hash,
    content_text,
    is_active,
    effective_date,
    created_by,
    change_summary
)
SELECT
    '1.0.0',
    encode(sha256('Default Terms of Service and Privacy Policy'::bytea), 'hex'),
    'Default Terms of Service and Privacy Policy',
    true,
    now(),
    'system',
    'Initial agreement version'
WHERE NOT EXISTS (
    SELECT 1 FROM public.agreement_versions
);

-- Clean up
DROP TABLE IF EXISTS user_migration_map;

-- Verify migration success
DO $$
DECLARE
    creators_without_users integer;
    ads_without_content integer;
BEGIN
    SELECT COUNT(*) INTO creators_without_users
    FROM public.creators
    WHERE user_id IS NULL AND email IS NOT NULL;
    
    SELECT COUNT(*) INTO ads_without_content
    FROM public.ads
    WHERE content IS NULL OR target_url IS NULL;
    
    IF creators_without_users > 0 THEN
        RAISE NOTICE 'Warning: % creators do not have linked users', creators_without_users;
    END IF;
    
    IF ads_without_content > 0 THEN
        RAISE NOTICE 'Warning: % ads are missing content or target_url', ads_without_content;
    END IF;
END $$;