# Database Migration Scripts

This directory contains SQL migration scripts to update the old database schema to support the new features added by the frontend team.

## Migration Order

Execute these migrations in sequence:

1. **001_add_drizzle_schema.sql**
   - Creates Drizzle ORM migration tracking schema

2. **002_add_auth_tables.sql**
   - Adds Better Auth and Frontend Auth tables
   - Creates OAuth support infrastructure

3. **003_add_api_key_tables.sql**
   - Adds modern API key management system
   - Includes permissions and rate limiting support

4. **004_add_agreement_tables.sql**
   - Adds legal agreement tracking system
   - Supports versioning and user acceptance

5. **005_add_admin_and_logging_tables.sql**
   - Adds admin session management
   - Creates comprehensive API logging

6. **006_modify_existing_tables.sql**
   - Updates existing tables with new columns
   - Handles column renames and type conversions
   - Adds necessary foreign keys

7. **007_data_migration.sql**
   - Migrates existing user data to new auth system
   - Links creators to new user accounts
   - Populates default values

8. **008_cleanup_and_constraints.sql**
   - Adds final constraints
   - Creates helpful views
   - Adds indexes for performance

## Pre-Migration Checklist

1. **Backup your database** before running migrations
2. Ensure pgvector extension is installed
3. Check PostgreSQL version compatibility (16+)
4. Review connection settings and timeouts

## Running Migrations

```bash
# Connect to your database
psql -U postgres -d your_database_name

# Run migrations in order
\i /path/to/migrations/001_add_drizzle_schema.sql
\i /path/to/migrations/002_add_auth_tables.sql
# ... continue for all migrations
```

Or run all at once:
```bash
for i in {001..008}; do
    psql -U postgres -d your_database_name -f /path/to/migrations/${i}_*.sql
done
```

## Post-Migration Steps

1. Verify all tables were created successfully
2. Check that data migration completed without errors
3. Update application configuration for new auth system
4. Test API key generation and authentication
5. Ensure vector embeddings are being stored correctly

## Rollback Strategy

Each migration should have a corresponding rollback script. In case of issues:
1. Restore from backup
2. Or manually reverse changes using the schema differences document

## Common Issues

- **Vector type errors**: Ensure pgvector extension is installed
- **Foreign key violations**: Run data cleanup before constraints
- **Permission errors**: Check database user has appropriate privileges
- **Timeout errors**: Increase statement_timeout for large tables