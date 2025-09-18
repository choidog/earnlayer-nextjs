-- Fix duplicate columns in verification table
-- Remove camelCase columns and keep only snake_case columns

-- First, check current verification table structure
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'verification' AND table_schema = 'public'
ORDER BY ordinal_position;

-- Drop the duplicate camelCase columns
ALTER TABLE "verification" DROP COLUMN IF EXISTS "expiresAt";
ALTER TABLE "verification" DROP COLUMN IF EXISTS "createdAt";
ALTER TABLE "verification" DROP COLUMN IF EXISTS "updatedAt";

-- Ensure the snake_case expires_at column is NOT NULL (as required by Better Auth)
ALTER TABLE "verification" ALTER COLUMN "expires_at" SET NOT NULL;

-- Verify the final structure
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_name = 'verification' AND table_schema = 'public'
ORDER BY ordinal_position;