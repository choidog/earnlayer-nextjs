# Migration Fix for Error 006

## The Problem

The `creators` table already has a `user_id` column of type UUID that references the old `users` table. We can't change its type or create a foreign key to `auth_users` (which uses text IDs).

## The Solution

Instead of trying to reuse the existing `user_id` column, we:

1. **Keep `user_id` as UUID** - Preserves link to original users table
2. **Add new `auth_user_id` column** - Links to new auth_users table (text IDs)

## Updated Structure

The `creators` table now has:
- `user_id` (UUID) - Links to legacy `users` table
- `auth_user_id` (text) - Links to new `auth_users` table
- Both can coexist without conflicts

## To Continue Migration

Run the updated migration 006:
```bash
railway run psql < migrations/006_modify_existing_tables.sql
```

Then continue with remaining migrations:
```bash
for i in {007..009}; do
    railway run psql < migrations/${i}_*.sql
done
```

## Code Updates Required

In your application code, use `auth_user_id` for new auth:

```typescript
// In Drizzle schema
export const creators = pgTable("creators", {
    id: uuid("id").defaultRandom().primaryKey(),
    user_id: uuid("user_id"), // Legacy - links to old users table
    auth_user_id: text("auth_user_id").references(() => authUsers.id), // New - links to auth_users
    // ... other fields
});

// When querying
const creator = await db.query.creators.findFirst({
    where: eq(creators.auth_user_id, authUser.id) // Use auth_user_id
});
```

This approach:
- Preserves all existing data
- Maintains referential integrity
- Allows gradual migration
- No type conflicts