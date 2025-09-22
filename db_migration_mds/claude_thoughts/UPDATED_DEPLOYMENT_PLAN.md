# Updated Deployment Plan: Clean Migration Strategy

## Key Changes Made

To avoid conflicts with the existing `users` table, the migrations now:

1. **Keep the original `users` table intact** (with UUID IDs and password auth)
2. **Create new `auth_users` table** for OAuth/Better Auth (with text IDs)
3. **Link tables appropriately** without breaking existing relationships

## New Table Structure

- `users` - Original table with UUID IDs (unchanged)
- `auth_users` - New OAuth users with text IDs
- `account` - OAuth account linkage (references auth_users)
- `session` - User sessions (references auth_users)
- `api_keys` - API keys (references auth_users)
- `user_agreements` - Agreement tracking (references auth_users)

## Step 1: Complete Current Migration

Since you've already run migration 001, continue with the updated migrations:

```bash
# Run migration 002 (creates auth_users, not users)
railway run psql < migrations/002_add_auth_tables.sql

# Continue with remaining migrations
for i in {003..009}; do
    echo "Applying migration $i..."
    railway run psql < migrations/${i}_*.sql
    
    if [ $? -ne 0 ]; then
        echo "Migration $i failed!"
        exit 1
    fi
done
```

## Step 2: Verify Dual User Tables

```bash
# Check both user tables exist
railway run psql -c "
SELECT 
    'users (original)' as table_type,
    COUNT(*) as count,
    'UUID IDs' as id_type
FROM users
UNION ALL
SELECT 
    'auth_users (new OAuth)',
    COUNT(*),
    'Text IDs'
FROM auth_users;"

# Verify creators are linked properly
railway run psql -c "
SELECT COUNT(*) as creators_linked_to_auth_users
FROM creators 
WHERE user_id IS NOT NULL 
AND user_id LIKE 'legacy_%';"
```

## Step 3: Update Application Code

Your co-founder needs to update the code to use the correct table:

### In `src/lib/db/schema.ts`:
```typescript
// The 'users' table name should be changed to 'auth_users'
export const users = pgTable("auth_users", {
    id: text("id").primaryKey(),
    email: text("email").notNull().unique(),
    name: text("name").notNull(),
    picture: text("picture"),
    email_verified: boolean("email_verified").default(false).notNull(),
    provider: text("provider").default("google").notNull(),
    created_at: timestamp("created_at").defaultNow().notNull(),
    updated_at: timestamp("updated_at").defaultNow().notNull(),
});

// Keep reference to legacy users if needed
export const legacyUsers = pgTable("users", {
    id: uuid("id").defaultRandom().primaryKey(),
    email: varchar("email", { length: 255 }).notNull(),
    password_hash: varchar("password_hash", { length: 255 }).notNull(),
    created_at: timestamp("created_at").defaultNow(),
    updated_at: timestamp("updated_at").defaultNow(),
    deleted_at: timestamp("deleted_at"),
});
```

### In Better Auth config:
```typescript
// Update table name references
auth: {
    database: {
        type: "postgres",
        // Update table mappings
        user: "auth_users",
        account: "account",
        session: "session",
    }
}
```

## Step 4: API Endpoints Update

All endpoints expecting the `users` table need to reference `auth_users`:

```typescript
// Example: /api/users/route.ts
// Change from:
const user = await db.query.users.findFirst({...});

// To:
const user = await db.query.authUsers.findFirst({...});
```

## Benefits of This Approach

1. **No data loss** - Original users table remains untouched
2. **Clean separation** - OAuth users separate from legacy password users
3. **Gradual migration** - Can migrate users from old to new system over time
4. **No broken references** - Existing foreign keys to users table still work

## Rollback Strategy

If issues arise:

```bash
# Just drop the new tables, original data is untouched
railway run psql -c "
DROP TABLE IF EXISTS auth_users CASCADE;
DROP TABLE IF EXISTS account CASCADE;
DROP TABLE IF EXISTS session CASCADE;
DROP TABLE IF EXISTS api_keys CASCADE;
DROP TABLE IF EXISTS api_key_usage CASCADE;
DROP TABLE IF EXISTS user_agreements CASCADE;
DROP TABLE IF EXISTS agreement_banner_dismissals CASCADE;
DROP TABLE IF EXISTS agreement_versions CASCADE;
DROP TABLE IF EXISTS admin_sessions CASCADE;
DROP TABLE IF EXISTS api_logs CASCADE;
DROP SCHEMA IF EXISTS drizzle CASCADE;"
```

## Important Notes for Your Co-founder

1. **Table Name Change**: All references to `users` table in the new auth system should use `auth_users`
2. **User ID Format**: auth_users has text IDs (e.g., "legacy_uuid" or "google_12345")
3. **Creator Linkage**: Creators are linked to auth_users via the user_id column
4. **Vector Search**: Keep using the `embeddings` table, not ads.embedding

## Quick Test After Migration

```bash
# Test creating an OAuth user
railway run psql -c "
INSERT INTO auth_users (id, email, name, provider) 
VALUES ('test_oauth_user', 'test@oauth.com', 'Test OAuth User', 'google')
RETURNING *;"

# Test that vector search still works
railway run psql -c "
SELECT COUNT(*) as vector_search_test
FROM embeddings 
WHERE embedding IS NOT NULL 
LIMIT 1;"
```