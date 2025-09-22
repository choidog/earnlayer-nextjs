-- =====================================================
-- SIMPLE DRIZZLE MIGRATION CHECKER
-- This will definitely show you all the output
-- =====================================================

-- Step 1: Check if migrations table exists
SELECT 
    CASE 
        WHEN EXISTS (
            SELECT 1 FROM information_schema.tables 
            WHERE table_schema = 'public' 
            AND table_name = '__drizzle_migrations'
        ) 
        THEN 'MIGRATIONS TABLE EXISTS' 
        ELSE 'MIGRATIONS TABLE DOES NOT EXIST' 
    END as step_1_result;

-- Step 2: Count total tables
SELECT 
    'TOTAL TABLES IN DATABASE: ' || (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public') as step_2_result;

-- Step 3: Check for key tables one by one
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'users')
        THEN 'USERS TABLE: EXISTS'
        ELSE 'USERS TABLE: MISSING'
    END as step_3a_result;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'sessions')
        THEN 'SESSIONS TABLE: EXISTS'
        ELSE 'SESSIONS TABLE: MISSING'
    END as step_3b_result;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'accounts')
        THEN 'ACCOUNTS TABLE: EXISTS'
        ELSE 'ACCOUNTS TABLE: MISSING'
    END as step_3c_result;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'creators')
        THEN 'CREATORS TABLE: EXISTS'
        ELSE 'CREATORS TABLE: MISSING'
    END as step_3d_result;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'ad_campaigns')
        THEN 'AD_CAMPAIGNS TABLE: EXISTS'
        ELSE 'AD_CAMPAIGNS TABLE: MISSING'
    END as step_3e_result;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'display_ads')
        THEN 'DISPLAY_ADS TABLE: EXISTS'
        ELSE 'DISPLAY_ADS TABLE: MISSING'
    END as step_3f_result;

-- Step 4: Check for custom types
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ad_placement')
        THEN 'AD_PLACEMENT ENUM: EXISTS'
        ELSE 'AD_PLACEMENT ENUM: MISSING'
    END as step_4a_result;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ad_status')
        THEN 'AD_STATUS ENUM: EXISTS'
        ELSE 'AD_STATUS ENUM: MISSING'
    END as step_4b_result;

SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM pg_type WHERE typname = 'ad_type')
        THEN 'AD_TYPE ENUM: EXISTS'
        ELSE 'AD_TYPE ENUM: MISSING'
    END as step_4c_result;

-- Step 5: List all tables in your database
SELECT 'ALL TABLES IN YOUR DATABASE:' as step_5_header;
SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' ORDER BY table_name;

-- Step 6: Final summary
SELECT 'FINAL SUMMARY:' as step_6_header;
SELECT 
    CASE 
        WHEN EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '__drizzle_migrations')
        THEN 'MIGRATIONS HAVE BEEN APPLIED - CHECK INDIVIDUAL RESULTS ABOVE'
        ELSE 'NO MIGRATIONS HAVE BEEN APPLIED - YOU NEED TO RUN YOUR MIGRATIONS'
    END as final_result;
