# Comprehensive Migration Testing Guide

## Pre-Migration Testing

### 1. Database Backup Verification
```bash
# Create timestamped backup
pg_dump -U postgres -d earnlayer -Fc -f "backup_$(date +%Y%m%d_%H%M%S).dump"

# Verify backup integrity
pg_restore -l backup_*.dump | head -20

# Test restore to separate database
createdb earnlayer_test
pg_restore -U postgres -d earnlayer_test backup_*.dump
```

### 2. Record Pre-Migration Metrics
```sql
-- Record current data counts
SELECT 'users' as table_name, COUNT(*) as count FROM users
UNION ALL SELECT 'creators', COUNT(*) FROM creators
UNION ALL SELECT 'ads', COUNT(*) FROM ads
UNION ALL SELECT 'ad_campaigns', COUNT(*) FROM ad_campaigns
UNION ALL SELECT 'advertisers', COUNT(*) FROM advertisers
UNION ALL SELECT 'ad_impressions', COUNT(*) FROM ad_impressions
UNION ALL SELECT 'embeddings', COUNT(*) FROM embeddings
UNION ALL SELECT 'chat_sessions', COUNT(*) FROM chat_sessions
UNION ALL SELECT 'chat_messages', COUNT(*) FROM chat_messages
UNION ALL SELECT 'creator_affiliate_codes', COUNT(*) FROM creator_affiliate_codes;

-- Save critical IDs for verification
CREATE TEMP TABLE pre_migration_samples AS
SELECT 'ads' as table_type, id, title, url, description FROM ads LIMIT 10
UNION ALL
SELECT 'creators', id::text, name, email, bio FROM creators LIMIT 10;
```

### 3. Vector Search Baseline Test
```sql
-- Test current vector search functionality
WITH query_embedding AS (
    SELECT embedding FROM embeddings 
    WHERE source_table = 'ads' 
    LIMIT 1
)
SELECT 
    a.id, 
    a.title,
    1 - (e.embedding <-> q.embedding) as similarity
FROM ads a
JOIN embeddings e ON e.source_id = a.id AND e.source_table = 'ads'
CROSS JOIN query_embedding q
ORDER BY similarity DESC
LIMIT 5;

-- Record the results for comparison after migration
```

## Migration Execution Tests

### 1. Migration Order Verification
```bash
# Run migrations in correct order
for i in {001..009}; do
    echo "Running migration $i..."
    psql -U postgres -d earnlayer -f migrations/${i}_*.sql
    if [ $? -ne 0 ]; then
        echo "Migration $i failed!"
        exit 1
    fi
done
```

### 2. Schema Verification After Each Migration

#### After Migration 001 (Drizzle Schema)
```sql
-- Verify drizzle schema exists
SELECT EXISTS (
    SELECT 1 FROM information_schema.schemata 
    WHERE schema_name = 'drizzle'
);

-- Verify migrations table exists
SELECT EXISTS (
    SELECT 1 FROM information_schema.tables 
    WHERE table_schema = 'drizzle' 
    AND table_name = '__drizzle_migrations'
);
```

#### After Migration 002 (Auth Tables)
```sql
-- Verify all auth tables exist
SELECT table_name FROM information_schema.tables 
WHERE table_schema = 'public' 
AND table_name IN ('users', 'account', 'session', 'user', 'verification', 'verification_token')
ORDER BY table_name;

-- Verify foreign keys
SELECT 
    tc.constraint_name, 
    tc.table_name, 
    kcu.column_name, 
    ccu.table_name AS foreign_table_name,
    ccu.column_name AS foreign_column_name 
FROM information_schema.table_constraints AS tc 
JOIN information_schema.key_column_usage AS kcu
    ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage AS ccu
    ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY' 
AND tc.table_name IN ('account', 'session');
```

#### After Migration 003 (API Keys)
```sql
-- Verify API key tables
SELECT 
    table_name,
    (SELECT COUNT(*) FROM information_schema.columns WHERE table_name = t.table_name) as column_count
FROM information_schema.tables t
WHERE table_name IN ('api_keys', 'api_key_usage', 'apikey')
ORDER BY table_name;

-- Verify indexes
SELECT indexname FROM pg_indexes 
WHERE tablename IN ('api_keys', 'api_key_usage')
ORDER BY indexname;
```

#### After Migration 004 (Agreements)
```sql
-- Verify agreement tables and constraints
SELECT 
    tc.table_name,
    tc.constraint_name,
    tc.constraint_type
FROM information_schema.table_constraints tc
WHERE tc.table_name LIKE '%agreement%'
ORDER BY tc.table_name, tc.constraint_type;

-- Verify unique constraints
SELECT * FROM pg_constraint 
WHERE conname LIKE '%agreement%unique%';
```

#### After Migration 005 (Admin & Logging)
```sql
-- Verify admin_sessions and api_logs
SELECT 
    table_name,
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_name IN ('admin_sessions', 'api_logs')
ORDER BY table_name, ordinal_position;

-- Check api_logs check constraint
SELECT 
    conname,
    pg_get_constraintdef(oid) 
FROM pg_constraint 
WHERE conname = 'check_api_logs_level';
```

#### After Migration 006 (Modify Existing Tables)
```sql
-- Verify creators modifications
SELECT 
    column_name,
    data_type,
    is_nullable
FROM information_schema.columns
WHERE table_name = 'creators'
AND column_name IN ('user_id', 'email', 'approval_status', 'permissions')
ORDER BY column_name;

-- Verify ads table has both old and new columns
SELECT 
    column_name,
    data_type
FROM information_schema.columns
WHERE table_name = 'ads'
AND column_name IN ('url', 'target_url', 'description', 'content', 'embedding', 'placement')
ORDER BY column_name;

-- Verify embeddings table is UNCHANGED
SELECT 
    column_name,
    udt_name
FROM information_schema.columns
WHERE table_name = 'embeddings'
ORDER BY ordinal_position;
```

#### After Migration 007 (Data Migration)
```sql
-- Verify user migration
SELECT 
    'frontend_users' as user_type,
    COUNT(*) as count
FROM public.users
WHERE id LIKE 'legacy_%'
UNION ALL
SELECT 
    'creators_with_users',
    COUNT(*)
FROM creators
WHERE user_id IS NOT NULL;

-- Verify data copying in ads
SELECT 
    COUNT(*) as total_ads,
    COUNT(target_url) as ads_with_target_url,
    COUNT(content) as ads_with_content,
    COUNT(CASE WHEN url = target_url THEN 1 END) as matching_urls,
    COUNT(CASE WHEN description = content THEN 1 END) as matching_content
FROM ads;

-- Check chat_messages conversion
SELECT 
    role,
    COUNT(*) as count
FROM chat_messages
GROUP BY role;
```

#### After Migration 008 (Cleanup)
```sql
-- Verify views exist
SELECT viewname FROM pg_views 
WHERE viewname IN ('v_users_with_creators', 'v_active_campaigns_ads');

-- Verify triggers
SELECT 
    trigger_name,
    event_object_table
FROM information_schema.triggers
WHERE trigger_name LIKE '%updated_at%'
ORDER BY event_object_table;
```

#### After Migration 009 (Embeddings Handling)
```sql
-- Verify embeddings compatibility
SELECT 
    routine_name,
    routine_type
FROM information_schema.routines
WHERE routine_name = 'sync_ad_embedding_to_table';

-- Verify trigger exists
SELECT EXISTS (
    SELECT 1 FROM pg_trigger 
    WHERE tgname = 'sync_ad_embedding_trigger'
);

-- Test embedding sync
UPDATE ads 
SET embedding = '[0.1, 0.2, 0.3]'
WHERE id = (SELECT id FROM ads LIMIT 1);

-- Check if synced to embeddings table
SELECT COUNT(*) FROM embeddings 
WHERE created_at > NOW() - INTERVAL '1 minute';
```

## Post-Migration Comprehensive Tests

### 1. Data Integrity Tests
```sql
-- Verify no data loss
WITH post_counts AS (
    SELECT 'users' as table_name, COUNT(*) as count FROM users
    UNION ALL SELECT 'creators', COUNT(*) FROM creators
    UNION ALL SELECT 'ads', COUNT(*) FROM ads
    UNION ALL SELECT 'ad_campaigns', COUNT(*) FROM ad_campaigns
    UNION ALL SELECT 'advertisers', COUNT(*) FROM advertisers
    UNION ALL SELECT 'ad_impressions', COUNT(*) FROM ad_impressions
    UNION ALL SELECT 'embeddings', COUNT(*) FROM embeddings
    UNION ALL SELECT 'chat_sessions', COUNT(*) FROM chat_sessions
    UNION ALL SELECT 'chat_messages', COUNT(*) FROM chat_messages
    UNION ALL SELECT 'creator_affiliate_codes', COUNT(*) FROM creator_affiliate_codes
)
SELECT 
    table_name,
    count as post_count
FROM post_counts
ORDER BY table_name;

-- Verify critical data preserved
SELECT 
    'ads' as check_type,
    COUNT(*) as matches
FROM ads a
JOIN pre_migration_samples p ON p.id = a.id
WHERE p.table_type = 'ads'
AND a.title = p.title
AND a.url = p.url
AND a.description = p.description;
```

### 2. Vector Search Tests
```sql
-- Test 1: Verify embeddings table still works
WITH test_embedding AS (
    SELECT embedding FROM embeddings 
    WHERE source_table = 'ads' 
    LIMIT 1
)
SELECT 
    a.id,
    a.title,
    1 - (e.embedding <-> t.embedding) as similarity
FROM ads a
JOIN embeddings e ON e.source_id = a.id AND e.source_table = 'ads'
CROSS JOIN test_embedding t
WHERE 1 - (e.embedding <-> t.embedding) > 0.5
ORDER BY similarity DESC
LIMIT 5;

-- Test 2: Verify ivfflat indexes are used
EXPLAIN (ANALYZE, BUFFERS) 
SELECT a.id, 1 - (e.embedding <-> '[0.1, 0.2, 0.3]'::vector) as similarity
FROM ads a
JOIN embeddings e ON e.source_id = a.id
ORDER BY e.embedding <-> '[0.1, 0.2, 0.3]'::vector
LIMIT 10;
```

### 3. Authentication System Tests
```sql
-- Test user creation
INSERT INTO users (id, email, name, provider) 
VALUES ('test_' || gen_random_uuid(), 'test@example.com', 'Test User', 'google')
RETURNING *;

-- Test OAuth account linkage
INSERT INTO account (id, account_id, provider_id, user_id)
VALUES (
    'test_acc_' || gen_random_uuid(),
    'google_123456',
    'google',
    (SELECT id FROM users WHERE email = 'test@example.com')
)
RETURNING *;

-- Test session creation
INSERT INTO session (id, user_id, token, expires_at)
VALUES (
    'test_session_' || gen_random_uuid(),
    (SELECT id FROM users WHERE email = 'test@example.com'),
    'test_token_' || gen_random_uuid(),
    NOW() + INTERVAL '7 days'
)
RETURNING *;
```

### 4. API Key Management Tests
```sql
-- Create API key
INSERT INTO api_keys (id, name, key, user_id, permissions)
VALUES (
    'test_key_' || gen_random_uuid(),
    'Test API Key',
    'sk_test_' || gen_random_uuid(),
    (SELECT id FROM users WHERE email = 'test@example.com'),
    '{"mcp": {"access": true}, "ads": {"read": true}}'::jsonb
)
RETURNING *;

-- Test API key usage tracking
INSERT INTO api_key_usage (
    id, api_key_id, endpoint, method, status_code, created_at
)
VALUES (
    'test_usage_' || gen_random_uuid(),
    (SELECT id FROM api_keys WHERE name = 'Test API Key'),
    '/api/ads/search',
    'POST',
    200,
    NOW()
)
RETURNING *;
```

### 5. Creator Workflow Tests
```sql
-- Test creator with new auth system
INSERT INTO creators (user_id, email, name, approval_status)
VALUES (
    (SELECT id FROM users WHERE email = 'test@example.com'),
    'test@example.com',
    'Test Creator',
    'pending'
)
RETURNING *;

-- Test approval workflow
UPDATE creators 
SET 
    approval_status = 'approved',
    approval_date = NOW(),
    permissions = '["mcp:access", "ads:read", "ads:write"]'::jsonb
WHERE email = 'test@example.com'
RETURNING *;
```

### 6. Agreement System Tests
```sql
-- Create test agreement
INSERT INTO agreement_versions (
    version_string,
    content_hash,
    content_text,
    is_active,
    effective_date
)
VALUES (
    'test_1.0.0',
    encode(sha256('Test agreement content'::bytea), 'hex'),
    'Test agreement content',
    false,
    NOW()
)
RETURNING *;

-- Test user agreement acceptance
INSERT INTO user_agreements (
    user_id,
    agreement_version_id,
    ip_address,
    user_agent
)
VALUES (
    (SELECT id FROM users WHERE email = 'test@example.com'),
    (SELECT id FROM agreement_versions WHERE version_string = 'test_1.0.0'),
    '127.0.0.1',
    'Mozilla/5.0 Test'
)
RETURNING *;
```

### 7. Ad System Integration Tests
```sql
-- Test ad with both old and new fields
SELECT 
    id,
    title,
    url,
    target_url,
    description,
    content,
    (url = target_url) as url_match,
    (description = content) as content_match,
    embedding IS NOT NULL as has_text_embedding
FROM ads
LIMIT 5;

-- Test embedding sync
WITH new_ad AS (
    INSERT INTO ads (
        campaign_id, title, url, target_url, description, content, embedding
    )
    VALUES (
        (SELECT id FROM ad_campaigns LIMIT 1),
        'Test Ad',
        'https://example.com',
        'https://example.com',
        'Test Description',
        'Test Description',
        '[0.1, 0.2, 0.3]'
    )
    RETURNING id
)
SELECT 
    a.id as ad_id,
    e.source_id as embedding_ad_id,
    e.embedding IS NOT NULL as has_vector
FROM new_ad a
LEFT JOIN embeddings e ON e.source_id = a.id AND e.source_table = 'ads';
```

### 8. Performance Tests
```sql
-- Test query performance with new indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT u.*, c.*
FROM users u
LEFT JOIN creators c ON c.user_id = u.id
WHERE u.email = 'test@example.com';

-- Test vector search performance
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*)
FROM embeddings e
WHERE e.embedding <-> '[0.1, 0.2, 0.3]'::vector < 0.5;
```

### 9. Rollback Test (On Test Database)
```sql
-- Test that backup can be restored
DROP DATABASE IF EXISTS earnlayer_rollback_test;
CREATE DATABASE earnlayer_rollback_test;

-- Restore from pre-migration backup
-- pg_restore -U postgres -d earnlayer_rollback_test backup_*.dump

-- Verify original schema restored
SELECT COUNT(*) FROM information_schema.tables 
WHERE table_schema = 'public' 
AND table_name NOT IN ('users', 'account', 'session', 'api_keys', 'api_key_usage');
```

## Application Integration Tests

### 1. MCP Server Vector Search Test
```typescript
// Test that MCP server still finds ads using vector search
const testQuery = "best AI tools for developers";
const embedding = await getEmbedding(testQuery);

const results = await db.execute(sql`
    WITH query AS (
        SELECT ${embedding}::vector as emb
    )
    SELECT 
        a.id,
        a.title,
        a.url,
        a.target_url,
        1 - (e.embedding <-> q.emb) AS similarity
    FROM ads a
    JOIN embeddings e ON e.source_id = a.id AND e.source_table = 'ads'
    CROSS JOIN query q
    WHERE 1 - (e.embedding <-> q.emb) >= 0.7
    ORDER BY similarity DESC
    LIMIT 5
`);

assert(results.length > 0, "Vector search should return results");
assert(results[0].similarity >= 0.7, "Results should meet similarity threshold");
```

### 2. Authentication Flow Test
```typescript
// Test new user registration
const newUser = await db.insert(users).values({
    id: `test_${Date.now()}`,
    email: 'integration@test.com',
    name: 'Integration Test',
    provider: 'google'
}).returning();

// Test creator profile creation
const creator = await db.insert(creators).values({
    user_id: newUser[0].id,
    email: newUser[0].email,
    name: 'Integration Creator',
    approval_status: 'pending'
}).returning();

// Test API key generation
const apiKey = await db.insert(apiKeys).values({
    id: nanoid(),
    name: 'Integration Key',
    key: `sk_test_${nanoid()}`,
    user_id: newUser[0].id,
    permissions: { mcp: { access: true } }
}).returning();

assert(apiKey[0].key.startsWith('sk_test_'), "API key should have correct prefix");
```

### 3. End-to-End Ad Serving Test
```typescript
// Create a test ad with embedding
const adText = "Advanced AI coding assistant";
const embedding = await getEmbedding(adText);

// Insert ad with text embedding
const ad = await db.insert(ads).values({
    campaign_id: testCampaignId,
    title: adText,
    url: 'https://example.com/ai-assistant',
    target_url: 'https://example.com/ai-assistant',
    description: 'AI assistant for developers',
    content: 'AI assistant for developers',
    embedding: JSON.stringify(Array.from(embedding))
}).returning();

// Wait for trigger to sync
await new Promise(resolve => setTimeout(resolve, 1000));

// Verify embedding was synced
const embeddings = await db.execute(sql`
    SELECT * FROM embeddings 
    WHERE source_id = ${ad[0].id} 
    AND source_table = 'ads'
`);

assert(embeddings.length > 0, "Embedding should be synced to embeddings table");

// Test vector search finds the ad
const searchResults = await db.execute(sql`
    SELECT a.*, 1 - (e.embedding <-> ${embedding}::vector) as similarity
    FROM ads a
    JOIN embeddings e ON e.source_id = a.id
    WHERE e.source_id = ${ad[0].id}
`);

assert(searchResults[0].similarity > 0.99, "Should find exact match with high similarity");
```

## Monitoring Checklist

- [ ] All migrations completed without errors
- [ ] Row counts match or exceed pre-migration counts
- [ ] Vector searches return results with correct similarity scores
- [ ] Authentication system accepts new user registrations
- [ ] API keys can be generated and validated
- [ ] Creator approval workflow functions correctly
- [ ] Agreement system tracks acceptances
- [ ] Embedding sync trigger works for new ads
- [ ] No foreign key constraint violations
- [ ] Application can connect and query successfully
- [ ] MCP server returns contextual ads
- [ ] Performance is comparable or better than pre-migration

## Rollback Procedure

If any critical test fails:

1. Stop the application
2. Restore from pre-migration backup:
   ```bash
   pg_restore -U postgres -d earnlayer -c backup_[timestamp].dump
   ```
3. Investigate failure cause
4. Fix migration scripts
5. Re-test on test database first
6. Retry migration during next maintenance window