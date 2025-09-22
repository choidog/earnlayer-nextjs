# Deployment Plan: Database Schema Migration

## Overview

This plan outlines how to completely replace the current Railway PostgreSQL database with your old schema (including data), then apply migrations to support the new features your co-founder built.

## Step 1: Backup Current Railway Database (Just in Case)

```bash
# Connect to Railway CLI
railway login

# Select your project and environment
railway link

# Create backup of current database (even though we're replacing it)
railway run pg_dump -Fc -f "railway_backup_$(date +%Y%m%d_%H%M%S).dump"

# Download the backup locally
railway run cat railway_backup_*.dump > local_railway_backup.dump
```

## Step 2: Prepare for Complete Database Replacement

### Option A: Drop and Recreate (Cleanest)

```bash
# Connect to Railway PostgreSQL
railway run psql

# Inside psql, drop EVERYTHING
DROP SCHEMA public CASCADE;
DROP SCHEMA IF EXISTS drizzle CASCADE;
CREATE SCHEMA public;
GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO public;

# Exit psql
\q
```

### Option B: Use Railway Database Reset (If Available)

Check Railway dashboard for database reset option, or:

```bash
# Delete and recreate the database service
railway service delete [database-service-name]
railway service create postgres
```

## Step 3: Import Your Old Schema with Data

```bash
# Method 1: Direct import via Railway CLI
railway run psql < schemas/cloud/cloud_schema_w_data.sql

# Method 2: If file is too large, upload first
railway run bash -c "cat > /tmp/schema.sql" < schemas/cloud/cloud_schema_w_data.sql
railway run psql -f /tmp/schema.sql

# Method 3: Using pg_restore if the file is a dump format
railway run pg_restore -d $PGDATABASE schemas/cloud/cloud_schema_w_data.sql
```

## Step 4: Verify Import Success

```bash
railway run psql -c "
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
ORDER BY table_name;"

# Check critical tables have data
railway run psql -c "
SELECT 'users' as table_name, COUNT(*) as count FROM users
UNION ALL SELECT 'creators', COUNT(*) FROM creators
UNION ALL SELECT 'ads', COUNT(*) FROM ads
UNION ALL SELECT 'embeddings', COUNT(*) FROM embeddings
UNION ALL SELECT 'advertisers', COUNT(*) FROM advertisers;"

# Verify pgvector extension
railway run psql -c "SELECT * FROM pg_extension WHERE extname = 'vector';"
```

## Step 5: Apply Migrations in Order

```bash
# Run each migration file
for i in {001..009}; do
    echo "Applying migration $i..."
    railway run psql < migrations/${i}_*.sql
    
    if [ $? -ne 0 ]; then
        echo "Migration $i failed! Check the error and fix before continuing."
        exit 1
    fi
    
    echo "Migration $i completed successfully."
done
```

## Step 6: Verify Migration Success

```bash
# Check new tables exist
railway run psql -c "
SELECT table_name 
FROM information_schema.tables 
WHERE table_schema = 'public' 
AND table_name IN ('users', 'api_keys', 'agreement_versions', 'admin_sessions')
ORDER BY table_name;"

# Verify embeddings table still has vector type
railway run psql -c "
SELECT column_name, udt_name 
FROM information_schema.columns 
WHERE table_name = 'embeddings';"

# Test vector search still works
railway run psql -c "
WITH test AS (
    SELECT embedding FROM embeddings LIMIT 1
)
SELECT COUNT(*) as vector_search_works
FROM embeddings e, test t
WHERE e.embedding <-> t.embedding < 0.5;"
```

## Step 7: Post-Migration Verification

```bash
# Run comprehensive verification
railway run psql < db_migration_mds/migration_testing.md

# Export final schema for documentation
railway run pg_dump --schema-only > final_migrated_schema.sql
```

## Step 8: Update Environment Variables

Ensure your Railway environment has:

```bash
# Database connection (should already be set by Railway)
DATABASE_URL=postgresql://...

# Required for new auth system
BETTER_AUTH_SECRET=<generate-secure-secret>
GOOGLE_CLIENT_ID=<your-google-oauth-client-id>
GOOGLE_CLIENT_SECRET=<your-google-oauth-secret>

# OpenAI for embeddings (should already exist)
OPENAI_API_KEY=<your-openai-key>
```

## Step 9: Deploy Updated Application Code

Your co-founder needs to:

1. Update database connection code to handle new schema
2. Ensure vector searches use `embeddings` table, not `ads.embedding`
3. Update auth to use new Better Auth tables
4. Test all endpoints with migrated database

## Quick Rollback Plan

If something goes wrong:

```bash
# Option 1: Restore original schema
railway run psql < schemas/cloud/cloud_schema_w_data.sql

# Option 2: Restore from Railway backup
railway run pg_restore -c -d $PGDATABASE railway_backup_*.dump
```

## Important Notes

1. **Timing**: Do this during low-traffic period
2. **Communication**: Notify your co-founder before starting
3. **Testing**: Have your co-founder ready to test immediately after
4. **Monitoring**: Watch application logs for any errors

## One-Line Command (Dangerous but Fast)

If you're confident and want to do it all at once:

```bash
# THIS WILL DESTROY CURRENT DATA - BE SURE!
railway run bash -c "
psql -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;' && \
psql < /dev/stdin && \
echo 'Schema imported, applying migrations...' && \
psql < migrations/001_add_drizzle_schema.sql && \
psql < migrations/002_add_auth_tables.sql && \
psql < migrations/003_add_api_key_tables.sql && \
psql < migrations/004_add_agreement_tables.sql && \
psql < migrations/005_add_admin_and_logging_tables.sql && \
psql < migrations/006_modify_existing_tables.sql && \
psql < migrations/007_data_migration.sql && \
psql < migrations/008_cleanup_and_constraints.sql && \
psql < migrations/009_handle_embeddings.sql && \
echo 'All migrations completed!'" < schemas/cloud/cloud_schema_w_data.sql
```

## Success Criteria

- [ ] All tables from old schema exist with data
- [ ] All new auth/api tables created
- [ ] Embeddings table has vector type (not text)
- [ ] Vector searches return results
- [ ] No foreign key violations
- [ ] Application can connect and query

## Next Steps for Co-founder

1. Update `src/lib/db/schema.ts` if needed
2. Ensure all vector searches use `embeddings` table
3. Test authentication flows
4. Verify MCP server returns ads correctly
5. Run full application test suite

## Contact During Migration

Have your co-founder on standby to:
- Test immediately after migration
- Update any code that breaks
- Monitor error logs
- Rollback if critical issues found