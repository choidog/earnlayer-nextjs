-- Migration: Add user_id column to creators table for Better Auth integration
-- This adds the missing user_id foreign key to link creators with Better Auth users

ALTER TABLE "creators" ADD COLUMN "user_id" text;
ALTER TABLE "creators" ADD CONSTRAINT "creators_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "user"("id") ON DELETE no action ON UPDATE no action;