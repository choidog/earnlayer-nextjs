# Code Migration Guide - FINAL VERSION

This guide provides instructions for migrating the codebase to work with the updated database architecture after all migrations have been applied.

## Critical Database Structure After Migration

**IMPORTANT**: The database now has multiple user-related tables:
- **`users`** - Original table with UUID IDs (legacy password auth) - KEPT INTACT
- **`auth_users`** - New OAuth table with text IDs (for Better Auth) - PRIMARY AUTH TABLE
- **`user`** - Better Auth compatibility table (if created by Better Auth)
- **`creators.user_id`** - Links to legacy `users` table (UUID)
- **`creators.auth_user_id`** - Links to `auth_users` table (text) - USE THIS

## What Your Co-founder Needs to Do

### 1. Update Better Auth Configuration
```typescript
// In your auth configuration file
export const auth = betterAuth({
  database: {
    type: "postgres",
    // CRITICAL: Use auth_users, not users
    user: "auth_users",
    account: "account", 
    session: "session",
  }
});
```

### 2. Update Drizzle Schema References
The schema should reference `auth_users` for authentication:
```typescript
// RENAME the table reference
export const authUsers = pgTable("auth_users", {
    id: text("id").primaryKey(),
    email: text("email").notNull().unique(),
    name: text("name").notNull(),
    picture: text("picture"),
    email_verified: boolean("email_verified").default(false).notNull(),
    provider: text("provider").default("google").notNull(),
    created_at: timestamp("created_at").defaultNow().notNull(),
    updated_at: timestamp("updated_at").defaultNow().notNull(),
});

// Update creators to use auth_user_id
export const creators = pgTable("creators", {
    id: uuid("id").defaultRandom().primaryKey(),
    user_id: uuid("user_id"), // Legacy - DO NOT USE
    auth_user_id: text("auth_user_id").references(() => authUsers.id), // USE THIS
    // ... rest of fields
});
```

### 3. Critical Query Updates
```typescript
// WRONG - Looking for creators by old user_id
const creator = await db.query.creators.findFirst({
  where: eq(creators.user_id, someId) // WRONG
});

// CORRECT - Use auth_user_id
const creator = await db.query.creators.findFirst({
  where: eq(creators.auth_user_id, authUser.id) // CORRECT
});
```

### 4. Vector Search - MUST USE embeddings table
```typescript
// WRONG - Using ads.embedding
const results = await db.select().from(ads)
  .where(sql`embedding::vector <-> ${vector}::vector < 0.5`); // WILL NOT WORK

// CORRECT - Join with embeddings table
const results = await db.execute(sql`
  SELECT a.*, 1 - (e.embedding <-> ${queryVector}::vector) as similarity
  FROM ads a
  JOIN embeddings e ON e.source_id = a.id AND e.source_table = 'ads'
  WHERE 1 - (e.embedding <-> ${queryVector}::vector) > 0.7
  ORDER BY similarity DESC
`);
```

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

**CRITICAL CHANGE**: The new auth system uses `auth_users` table, NOT `users` table.

#### Update the users table definition:
```typescript
// CHANGE THIS:
export const users = pgTable("users", {
    id: text("id").primaryKey(),
    // ...
});

// TO THIS:
export const authUsers = pgTable("auth_users", {
    id: text("id").primaryKey(),
    email: text("email").notNull().unique(),
    name: text("name").notNull(),
    picture: text("picture"),
    email_verified: boolean("email_verified").default(false).notNull(),
    provider: text("provider").default("google").notNull(),
    created_at: timestamp("created_at").defaultNow().notNull(),
    updated_at: timestamp("updated_at").defaultNow().notNull(),
});

// Keep the original users table reference if needed:
export const legacyUsers = pgTable("users", {
    id: uuid("id").defaultRandom().primaryKey(),
    email: varchar("email", { length: 255 }).notNull(),
    password_hash: varchar("password_hash", { length: 255 }).notNull(),
    created_at: timestamp("created_at", { withTimezone: true }).defaultNow(),
    updated_at: timestamp("updated_at", { withTimezone: true }).defaultNow(),
    deleted_at: timestamp("deleted_at", { withTimezone: true }),
});
```

#### Update all foreign key references:
```typescript
// In creators table definition:
user_id: text("user_id").references(() => authUsers.id), // NOT users.id

// In apiKeys table:
user_id: text("user_id").notNull().references(() => authUsers.id, { onDelete: "cascade" }),

// In userAgreements table:
user_id: text("user_id").notNull().references(() => authUsers.id, { onDelete: "cascade" }),
```

#### Update relations:
```typescript
// CHANGE THIS:
export const usersRelations = relations(users, ({ many }) => ({
    creators: many(creators),
    apiKeys: many(apiKeys),
    // ...
}));

// TO THIS:
export const authUsersRelations = relations(authUsers, ({ many }) => ({
    creators: many(creators),
    apiKeys: many(apiKeys),
    userAgreements: many(userAgreements),
    agreementBannerDismissals: many(agreementBannerDismissals),
}));

// Update creators relation:
export const creatorsRelations = relations(creators, ({ one, many }) => ({
    user: one(authUsers, { fields: [creators.user_id], references: [authUsers.id] }), // NOT users
    // ...
}));
```

### 4. Update API Routes

#### Authentication Routes (`/api/auth/`)
**CRITICAL**: Update Better Auth configuration to use `auth_users` table:
```typescript
// In your auth configuration
export const auth = betterAuth({
  database: {
    type: "postgres",
    // Update table names
    user: "auth_users", // NOT "users"
    account: "account",
    session: "session",
  }
});
```

#### User Management (`/api/users/`)
Update all queries to use the new table:
```typescript
// CHANGE THIS:
const user = await db.query.users.findFirst({
  where: eq(users.email, email)
});

// TO THIS:
const user = await db.query.authUsers.findFirst({
  where: eq(authUsers.email, email)
});

// Or if you need to query legacy users:
const legacyUser = await db.query.legacyUsers.findFirst({
  where: eq(legacyUsers.id, uuid)
});
```

#### Creator Endpoints
```typescript
// When creating a creator for an auth user:
const creator = await db.insert(creators).values({
  user_id: authUser.id, // This is now a text ID like "legacy_uuid" or "google_12345"
  email: authUser.email,
  name: authUser.name,
  // ...
});
```

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

**CRITICAL**: The old system uses a separate `embeddings` table with native vector type. DO NOT break this!

```typescript
// The embeddings table structure must be preserved:
// - source_table: 'ads' or 'content'  
// - source_id: UUID of the ad/content
// - embedding: vector(1536) type
// - chunk_id: 0 for primary embedding

// For new code compatibility, ads.embedding is text, but real vectors are in embeddings table
// When storing new embeddings:
const embeddingArray = Array.from(embedding);
const embeddingText = JSON.stringify(embeddingArray);

// Store in ads table (for new code compatibility)
await db.insert(ads).values({
  ...adData,
  embedding: embeddingText
});

// The migration includes a trigger to sync to embeddings table
// Or manually insert into embeddings table:
await db.execute(sql`
  INSERT INTO embeddings (source_table, source_id, embedding, chunk_id)
  VALUES ('ads', ${adId}, ${embeddingArray}::vector, 0)
  ON CONFLICT (source_table, source_id, chunk_id) 
  DO UPDATE SET embedding = EXCLUDED.embedding
`);

// For vector searches, ALWAYS use the embeddings table:
const results = await db.execute(sql`
  SELECT a.*, 1 - (e.embedding <-> ${queryEmbedding}::vector) as similarity
  FROM ads a
  JOIN embeddings e ON e.source_id = a.id AND e.source_table = 'ads'
  WHERE 1 - (e.embedding <-> ${queryEmbedding}::vector) > 0.7
  ORDER BY similarity DESC
`);
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

# If Better Auth needs table name configuration
BETTER_AUTH_USER_TABLE=auth_users
```

### 9. Testing After Migration

Run these tests to verify the migration:

```typescript
// Test user creation in NEW auth_users table
const testUser = await db.insert(authUsers).values({
  id: 'test_' + Date.now(),
  email: 'test@example.com',
  name: 'Test User',
  provider: 'google'
}).returning();

// Test creator linkage to auth_users
const testCreator = await db.insert(creators).values({
  user_id: testUser[0].id, // Text ID from auth_users
  email: testUser[0].email,
  name: 'Test Creator',
  approval_status: 'pending'
}).returning();

// Test API key generation linked to auth_users
const testApiKey = await db.insert(apiKeys).values({
  id: nanoid(),
  name: 'Test Key',
  key: 'test_' + nanoid(),
  user_id: testUser[0].id, // Text ID from auth_users
  permissions: { mcp: { access: true } }
}).returning();

// Verify legacy users still accessible
const legacyUserCount = await db.select({ count: count() })
  .from(legacyUsers);
console.log('Legacy users preserved:', legacyUserCount);
```

### 10. Common Issues and Fixes

#### Issue: "relation 'users' does not exist"
**Fix**: The auth system now uses `auth_users` table. Update all references:
```typescript
// Wrong
db.query.users.findFirst()

// Correct
db.query.authUsers.findFirst()
```

#### Issue: "column creators.user_id does not exist"
**Fix**: Run migration 006 to add the column

#### Issue: "invalid input syntax for type uuid"
**Fix**: The new auth_users table uses text IDs, not UUIDs:
```typescript
// If you have a UUID from legacy system
const authUserId = 'legacy_' + legacyUuid;
```

#### Issue: "relation 'public.users' does not exist" in Better Auth
**Fix**: Configure Better Auth to use correct table:
```typescript
betterAuth({
  database: {
    user: "auth_users", // NOT "users"
  }
})
```

#### Issue: Vector search not working
**Fix**: Ensure you're using the embeddings table, NOT ads.embedding:
```sql
-- WRONG: Using ads.embedding (text field)
SELECT * FROM ads WHERE embedding::vector <-> $1::vector < 0.3

-- CORRECT: Using embeddings table (vector field)
SELECT a.*, 1 - (e.embedding <-> $1::vector) as similarity
FROM ads a
JOIN embeddings e ON e.source_id = a.id AND e.source_table = 'ads'
WHERE 1 - (e.embedding <-> $1::vector) > 0.7
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
- [ ] Both `users` (legacy) and `auth_users` (new) tables exist
- [ ] Users can authenticate via Google OAuth into `auth_users` table
- [ ] API keys can be generated and linked to `auth_users`
- [ ] Creators can be linked to `auth_users` (not legacy `users`)
- [ ] Ad serving endpoints return data
- [ ] Vector search returns relevant results using `embeddings` table
- [ ] Chat sessions can be created
- [ ] Analytics queries work
- [ ] Admin panel accessible
- [ ] Better Auth configured to use `auth_users` table
- [ ] All imports/queries updated from `users` to `authUsers`
- [ ] No TypeScript errors in build

## Critical Checklist for Your Co-founder

### Must Update:
- [ ] Better Auth config to use `auth_users` table
- [ ] All imports from `users` to `authUsers` in schema
- [ ] All queries using `creators.user_id` to use `creators.auth_user_id`
- [ ] All vector searches to JOIN with `embeddings` table
- [ ] Remove any code trying to store embeddings in `ads.embedding`

### Must NOT Do:
- [ ] Don't use `creators.user_id` for new auth (it's for legacy users)
- [ ] Don't store vectors as text in ads table
- [ ] Don't query `users` table for OAuth users
- [ ] Don't drop the `embeddings` table

### Testing Priority:
1. **Auth Flow**: User can log in via Google OAuth
2. **Creator Link**: New OAuth users get linked to creators via `auth_user_id`
3. **Vector Search**: MCP server returns relevant ads
4. **API Keys**: Can generate and use API keys linked to `auth_users`

## Quick Diagnostic Queries

Run these to verify the migration worked:

```sql
-- Check user tables
SELECT 'users (legacy)' as table_name, COUNT(*) as count FROM users
UNION SELECT 'auth_users', COUNT(*) FROM auth_users;

-- Check creator linkages
SELECT 
  COUNT(*) FILTER (WHERE user_id IS NOT NULL) as legacy_links,
  COUNT(*) FILTER (WHERE auth_user_id IS NOT NULL) as auth_links
FROM creators;

-- Verify embeddings table
SELECT COUNT(*) as vector_count FROM embeddings WHERE source_table = 'ads';

-- Check foreign keys
SELECT conname, conrelid::regclass, confrelid::regclass
FROM pg_constraint
WHERE contype = 'f' 
AND (conrelid::regclass::text LIKE '%creators%' OR confrelid::regclass::text LIKE '%auth_users%');
```

## If Things Break

1. **"relation 'users' does not exist"** - Update to use `auth_users`
2. **"column creators.user_id is of type uuid"** - Use `creators.auth_user_id` instead
3. **Vector search returns no results** - Ensure joining with `embeddings` table
4. **Better Auth can't find users** - Check auth config points to `auth_users`

## Support

The database now has both legacy and new auth systems coexisting. Focus on using `auth_users` and `auth_user_id` for all new code.