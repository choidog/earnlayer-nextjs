-- =====================================================
-- DRIZZLE MIGRATION STATUS CHECKER
-- Copy and paste this entire script into pgAdmin
-- =====================================================

-- First, let's check if the Drizzle migrations table exists
SELECT 
    CASE 
        WHEN EXISTS (
            SELECT 1 FROM information_schema.tables 
            WHERE table_schema = 'public' 
            AND table_name = '__drizzle_migrations'
        ) 
        THEN '✅ Drizzle migrations table EXISTS' 
        ELSE '❌ Drizzle migrations table NOT FOUND' 
    END as migration_table_status;

-- Check if the table exists and show its structure
SELECT 
    'Migration table structure:' as info,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns 
WHERE table_schema = 'public' 
AND table_name = '__drizzle_migrations'
ORDER BY ordinal_position;

-- Show all applied migrations (if table exists)
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN 'Applied Migrations:'
        ELSE 'No migrations table found - no migrations have been applied yet'
    END as migration_status;

-- Only try to show migrations if the table exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations') THEN
        -- This will be executed as a separate query
        NULL;
    END IF;
END $$;

-- Show applied migrations (only if table exists)
-- Note: This query will only run if the migrations table exists
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN 'Migrations found - see details below'
        ELSE 'No migrations table - no migrations have been applied'
    END as migration_details;

-- Check for specific tables that should exist based on your migrations
-- Based on your migration files, these are the expected tables:

SELECT 'Expected Tables Check:' as info;

-- Check for core tables from migration 0000
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'users')
        THEN '✅ users table exists'
        ELSE '❌ users table missing'
    END as users_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'sessions')
        THEN '✅ sessions table exists'
        ELSE '❌ sessions table missing'
    END as sessions_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'accounts')
        THEN '✅ accounts table exists'
        ELSE '❌ accounts table missing'
    END as accounts_status;

-- Check for creator-related tables
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'creators')
        THEN '✅ creators table exists'
        ELSE '❌ creators table missing'
    END as creators_status;

-- Check for ad-related tables (from migration 0007)
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'ad_campaigns')
        THEN '✅ ad_campaigns table exists'
        ELSE '❌ ad_campaigns table missing'
    END as ad_campaigns_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'display_ads')
        THEN '✅ display_ads table exists'
        ELSE '❌ display_ads table missing'
    END as display_ads_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'contextual_ads')
        THEN '✅ contextual_ads table exists'
        ELSE '❌ contextual_ads table missing'
    END as contextual_ads_status;

-- Check for custom types that should exist
SELECT 'Custom Types Check:' as info;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ad_placement')
        THEN '✅ ad_placement enum exists'
        ELSE '❌ ad_placement enum missing'
    END as ad_placement_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ad_status')
        THEN '✅ ad_status enum exists'
        ELSE '❌ ad_status enum missing'
    END as ad_status_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ad_type')
        THEN '✅ ad_type enum exists'
        ELSE '❌ ad_type enum missing'
    END as ad_type_status;

-- Get a comprehensive list of all tables in your database
SELECT 'All Tables in Database:' as info;
SELECT 
    table_schema,
    table_name,
    table_type
FROM information_schema.tables 
WHERE table_schema = 'public'
ORDER BY table_name;

-- Check for any tables that might indicate partial migration
SELECT 'Tables with "ad" in name:' as info;
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
AND table_name LIKE '%ad%'
ORDER BY table_name;

-- Summary query - this will give you a quick overview
SELECT 
    'MIGRATION SUMMARY' as section,
    (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public') as total_tables,
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN 'Migrations table exists - check applied count above'
        ELSE 'No migrations table - 0 migrations applied'
    END as applied_migrations,
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN 'Check migration details above'
        ELSE 'No migrations applied'
    END as latest_migration_id;

-- Expected migration IDs based on your journal.json:
-- 0: 0000_dashing_hobgoblin
-- 1: 0001_smiling_ultimo  
-- 2: 0002_adorable_serpent_society
-- 3: 0003_aberrant_gorilla_man
-- 4: 0004_fix_better_auth_schema
-- 5: 0005_fix_id_column_types
-- 6: 0006_add_user_id_to_creators
-- 7: 0007_create_ads_tables
-- 8: 0008_fix_duplicate_columns (this one might not be in journal yet)

SELECT 'Expected Migration IDs:' as info;
SELECT 
    'You should see migration IDs 0-7 (and possibly 8) in the applied migrations list above' as note;
