# Code Migration Guide

This guide provides instructions for migrating the codebase to work with the updated database architecture.

## Overview

The main changes involve:
1. User authentication system (UUID → text-based IDs)
2. Table and column name changes
3. New foreign key relationships
4. Vector embedding format changes
5. API key management restructuring

## Step-by-Step Migration Instructions

### 1. Update Database Connection Configuration

Ensure your database connection in `src/lib/db/connection.ts` has proper timeout settings:

```typescript
connectionTimeoutMillis: 60000,  // Increase for migrations
query_timeout: 60000,
statement_timeout: 60000,
idle_in_transaction_session_timeout: 120000
```

### 2. Run Database Migrations

```bash
# First, backup your database
pg_dump -U postgres -d your_db > backup_$(date +%Y%m%d_%H%M%S).sql

# Run migrations in order
cd migrations
for i in {001..008}; do
    echo "Running migration $i..."
    psql -U postgres -d your_db -f ${i}_*.sql
done
```

### 3. Update Drizzle Schema (`src/lib/db/schema.ts`)

The current schema file should already be compatible, but verify:

#### User ID References
- All user ID references should be `text` type, not `uuid`
- Foreign keys should reference `users.id` (text), not the old UUID users

#### Column Name Mappings
The schema already uses the new column names:
- `ads.content` (not `description`)
- `ads.target_url` (not `url`) 
- `chat_messages.content` (not `message`)
- `chat_messages.role` (not `is_user`)

### 4. Update API Routes

#### Authentication Routes (`/api/auth/`)
- Already using Better Auth, should work as-is
- Verify OAuth callbacks are configured correctly

#### User Management (`/api/users/`)
- User IDs are now text-based from OAuth providers
- Update any UUID validation to accept text IDs
- Example fix:
```typescript
// Old
const userId = z.string().uuid().parse(params.userId);

// New
const userId = z.string().parse(params.userId);
```

#### Creator Endpoints
- Ensure creator lookups use the new `user_id` foreign key
- Update email field references (now required on creators table)

### 5. Update API Key Management

The new system uses dedicated `api_keys` table instead of storing in creators:

```typescript
// Old approach (if used)
const creator = await db.query.creators.findFirst({
  where: eq(creators.api_key, apiKey)
});

// New approach
const apiKeyRecord = await db.query.apiKeys.findFirst({
  where: eq(apiKeys.key, apiKey)
});
```

### 6. Update Vector Embedding Handling

Embeddings are now stored as text instead of native vector type:

```typescript
// When storing embeddings
const embeddingText = JSON.stringify(Array.from(embedding));
await db.insert(ads).values({
  ...adData,
  embedding: embeddingText
});

// When querying with embeddings
const embeddingVector = `[${embedding.join(',')}]`;
// Use text-based vector operations or convert in query
```

### 7. Update Chat Message Handling

```typescript
// Old format
await db.insert(chatMessages).values({
  message: content,
  is_user: true
});

// New format
await db.insert(chatMessages).values({
  content: content,
  role: 'user' // 'user', 'assistant', or 'system'
});
```

### 8. Environment Variables

Update `.env` files:
```bash
# Add if not present
DATABASE_URL=postgresql://user:pass@host:5432/dbname
BETTER_AUTH_SECRET=your-secret-key
GOOGLE_CLIENT_ID=your-google-client-id
GOOGLE_CLIENT_SECRET=your-google-client-secret
```

### 9. Testing After Migration

Run these tests to verify the migration:

```typescript
// Test user creation
const testUser = await db.insert(users).values({
  id: 'test_' + Date.now(),
  email: 'test@example.com',
  name: 'Test User',
  provider: 'google'
}).returning();

// Test creator linkage
const testCreator = await db.insert(creators).values({
  user_id: testUser[0].id,
  email: testUser[0].email,
  name: 'Test Creator',
  approval_status: 'pending'
}).returning();

// Test API key generation
const testApiKey = await db.insert(apiKeys).values({
  id: nanoid(),
  name: 'Test Key',
  key: 'test_' + nanoid(),
  user_id: testUser[0].id,
  permissions: { mcp: { access: true } }
}).returning();
```

### 10. Common Issues and Fixes

#### Issue: "column creators.user_id does not exist"
**Fix**: Run migration 006 to add the column

#### Issue: "invalid input syntax for type uuid"
**Fix**: Update code to use text IDs instead of UUIDs for users

#### Issue: Vector search not working
**Fix**: Update vector search queries to handle text-based embeddings:
```sql
-- Convert text back to vector for searching
embedding::vector <-> $1::vector
```

#### Issue: Auth not working
**Fix**: Ensure Better Auth tables are created and OAuth is configured

### 11. Rollback Plan

If issues occur:
```bash
# Restore from backup
psql -U postgres -d your_db < backup_YYYYMMDD_HHMMSS.sql

# Or create rollback migrations
```

### 12. Final Verification Checklist

- [ ] All migrations ran successfully
- [ ] Users can authenticate via Google OAuth
- [ ] API keys can be generated and used
- [ ] Creators can be linked to users
- [ ] Ad serving endpoints return data
- [ ] Vector search returns relevant results
- [ ] Chat sessions can be created
- [ ] Analytics queries work
- [ ] Admin panel accessible
- [ ] No TypeScript errors in build

## Deployment Notes

1. Run migrations during maintenance window
2. Deploy code changes immediately after migrations
3. Monitor error logs for any issues
4. Have rollback plan ready

## Support

For issues during migration:
1. Check migration logs for errors
2. Verify all foreign key relationships
3. Ensure vector extension is properly installed
4. Review this guide for common fixes