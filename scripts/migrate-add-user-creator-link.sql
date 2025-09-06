-- Migration: Add user_id to creators table and link existing data
-- Run this script against the production database

BEGIN;

-- Add user_id column to creators table
ALTER TABLE creators ADD COLUMN user_id TEXT;

-- Add foreign key constraint (after data migration)
-- ALTER TABLE creators ADD CONSTRAINT fk_creators_user_id FOREIGN KEY (user_id) REFERENCES "user"(id);

-- For existing creators without linked users, you'll need to manually decide how to handle them
-- Option 1: Leave user_id as NULL for existing creators (they can still be accessed via creator_id)
-- Option 2: Create dummy users for existing creators
-- Option 3: Remove orphaned creators

-- Example: Create a default user for existing creators (uncomment if needed)
/*
-- Insert a default "system" user for existing creators
INSERT INTO "user" (id, name, email, email_verified, created_at, updated_at)
VALUES ('system-user', 'System User', 'system@earnlayer.app', true, NOW(), NOW())
ON CONFLICT (id) DO NOTHING;

-- Link existing creators to system user
UPDATE creators 
SET user_id = 'system-user' 
WHERE user_id IS NULL;
*/

-- Note: The foreign key constraint is commented out above
-- Add it after you've decided how to handle existing data
-- ALTER TABLE creators ADD CONSTRAINT fk_creators_user_id FOREIGN KEY (user_id) REFERENCES "user"(id);

COMMIT;