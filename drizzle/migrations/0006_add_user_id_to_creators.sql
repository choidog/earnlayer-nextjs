-- Migration: Add user_id column to creators table for Better Auth integration
-- This adds the missing user_id foreign key to link creators with Better Auth users

-- Only add column if it doesn't exist
DO $$ 
BEGIN 
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='creators' AND column_name='user_id') THEN
        ALTER TABLE "creators" ADD COLUMN "user_id" text;
    END IF;
END $$;

-- Only add constraint if it doesn't exist  
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints WHERE constraint_name='creators_user_id_user_id_fk') THEN
        ALTER TABLE "creators" ADD CONSTRAINT "creators_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "user"("id") ON DELETE no action ON UPDATE no action;
    END IF;
END $$;