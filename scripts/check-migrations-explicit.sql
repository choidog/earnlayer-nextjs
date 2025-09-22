-- =====================================================
-- EXPLICIT DRIZZLE MIGRATION STATUS CHECKER
-- This script will explicitly tell you which migrations have been applied
-- =====================================================

-- First, check if the Drizzle migrations table exists
SELECT 
    CASE 
        WHEN EXISTS (
            SELECT 1 FROM information_schema.tables 
            WHERE table_schema = 'public' 
            AND table_name = '__drizzle_migrations'
        ) 
        THEN '✅ DRIZZLE MIGRATIONS TABLE EXISTS' 
        ELSE '❌ DRIZZLE MIGRATIONS TABLE DOES NOT EXIST - NO MIGRATIONS APPLIED' 
    END as migration_table_status;

-- If migrations table exists, show all applied migrations
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN 'APPLIED MIGRATIONS:'
        ELSE 'NO MIGRATIONS TABLE - NO MIGRATIONS HAVE BEEN APPLIED'
    END as applied_migrations_header;

-- Show each migration explicitly
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        AND EXISTS (SELECT 1 FROM public.__drizzle_migrations WHERE id = 0)
        THEN '✅ MIGRATION 0 (0000_dashing_hobgoblin) - APPLIED'
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN '❌ MIGRATION 0 (0000_dashing_hobgoblin) - NOT APPLIED'
        ELSE '❌ MIGRATION 0 (0000_dashing_hobgoblin) - NOT APPLIED (no migrations table)'
    END as migration_0_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        AND EXISTS (SELECT 1 FROM public.__drizzle_migrations WHERE id = 1)
        THEN '✅ MIGRATION 1 (0001_smiling_ultimo) - APPLIED'
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN '❌ MIGRATION 1 (0001_smiling_ultimo) - NOT APPLIED'
        ELSE '❌ MIGRATION 1 (0001_smiling_ultimo) - NOT APPLIED (no migrations table)'
    END as migration_1_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        AND EXISTS (SELECT 1 FROM public.__drizzle_migrations WHERE id = 2)
        THEN '✅ MIGRATION 2 (0002_adorable_serpent_society) - APPLIED'
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN '❌ MIGRATION 2 (0002_adorable_serpent_society) - NOT APPLIED'
        ELSE '❌ MIGRATION 2 (0002_adorable_serpent_society) - NOT APPLIED (no migrations table)'
    END as migration_2_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        AND EXISTS (SELECT 1 FROM public.__drizzle_migrations WHERE id = 3)
        THEN '✅ MIGRATION 3 (0003_aberrant_gorilla_man) - APPLIED'
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN '❌ MIGRATION 3 (0003_aberrant_gorilla_man) - NOT APPLIED'
        ELSE '❌ MIGRATION 3 (0003_aberrant_gorilla_man) - NOT APPLIED (no migrations table)'
    END as migration_3_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        AND EXISTS (SELECT 1 FROM public.__drizzle_migrations WHERE id = 4)
        THEN '✅ MIGRATION 4 (0004_fix_better_auth_schema) - APPLIED'
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN '❌ MIGRATION 4 (0004_fix_better_auth_schema) - NOT APPLIED'
        ELSE '❌ MIGRATION 4 (0004_fix_better_auth_schema) - NOT APPLIED (no migrations table)'
    END as migration_4_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        AND EXISTS (SELECT 1 FROM public.__drizzle_migrations WHERE id = 5)
        THEN '✅ MIGRATION 5 (0005_fix_id_column_types) - APPLIED'
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN '❌ MIGRATION 5 (0005_fix_id_column_types) - NOT APPLIED'
        ELSE '❌ MIGRATION 5 (0005_fix_id_column_types) - NOT APPLIED (no migrations table)'
    END as migration_5_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        AND EXISTS (SELECT 1 FROM public.__drizzle_migrations WHERE id = 6)
        THEN '✅ MIGRATION 6 (0006_add_user_id_to_creators) - APPLIED'
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN '❌ MIGRATION 6 (0006_add_user_id_to_creators) - NOT APPLIED'
        ELSE '❌ MIGRATION 6 (0006_add_user_id_to_creators) - NOT APPLIED (no migrations table)'
    END as migration_6_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        AND EXISTS (SELECT 1 FROM public.__drizzle_migrations WHERE id = 7)
        THEN '✅ MIGRATION 7 (0007_create_ads_tables) - APPLIED'
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN '❌ MIGRATION 7 (0007_create_ads_tables) - NOT APPLIED'
        ELSE '❌ MIGRATION 7 (0007_create_ads_tables) - NOT APPLIED (no migrations table)'
    END as migration_7_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        AND EXISTS (SELECT 1 FROM public.__drizzle_migrations WHERE id = 8)
        THEN '✅ MIGRATION 8 (0008_fix_duplicate_columns) - APPLIED'
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN '❌ MIGRATION 8 (0008_fix_duplicate_columns) - NOT APPLIED'
        ELSE '❌ MIGRATION 8 (0008_fix_duplicate_columns) - NOT APPLIED (no migrations table)'
    END as migration_8_status;

-- Check for key tables that should exist after migrations
SELECT 'KEY TABLES STATUS:' as info;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'users')
        THEN '✅ USERS TABLE EXISTS'
        ELSE '❌ USERS TABLE MISSING'
    END as users_table_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'sessions')
        THEN '✅ SESSIONS TABLE EXISTS'
        ELSE '❌ SESSIONS TABLE MISSING'
    END as sessions_table_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'accounts')
        THEN '✅ ACCOUNTS TABLE EXISTS'
        ELSE '❌ ACCOUNTS TABLE MISSING'
    END as accounts_table_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'creators')
        THEN '✅ CREATORS TABLE EXISTS'
        ELSE '❌ CREATORS TABLE MISSING'
    END as creators_table_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'ad_campaigns')
        THEN '✅ AD_CAMPAIGNS TABLE EXISTS'
        ELSE '❌ AD_CAMPAIGNS TABLE MISSING'
    END as ad_campaigns_table_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'display_ads')
        THEN '✅ DISPLAY_ADS TABLE EXISTS'
        ELSE '❌ DISPLAY_ADS TABLE MISSING'
    END as display_ads_table_status;

-- Check for custom types
SELECT 'CUSTOM TYPES STATUS:' as info;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ad_placement')
        THEN '✅ AD_PLACEMENT ENUM EXISTS'
        ELSE '❌ AD_PLACEMENT ENUM MISSING'
    END as ad_placement_enum_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ad_status')
        THEN '✅ AD_STATUS ENUM EXISTS'
        ELSE '❌ AD_STATUS ENUM MISSING'
    END as ad_status_enum_status;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ad_type')
        THEN '✅ AD_TYPE ENUM EXISTS'
        ELSE '❌ AD_TYPE ENUM MISSING'
    END as ad_type_enum_status;

-- Final summary
SELECT 'FINAL SUMMARY:' as info;

SELECT 
    'Total tables in database: ' || (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public') as total_tables;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN 'Migrations table exists - check individual migration status above'
        ELSE 'NO MIGRATIONS HAVE BEEN APPLIED - RUN YOUR MIGRATIONS FIRST'
    END as final_status;
