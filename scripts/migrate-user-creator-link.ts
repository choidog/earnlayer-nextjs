#!/usr/bin/env tsx
/**
 * Migration Script: Link Users and Creators
 * 
 * This script adds the user_id column to the creators table and handles
 * the migration of existing data.
 * 
 * Usage:
 *   npx tsx scripts/migrate-user-creator-link.ts
 */

import { db } from "../src/lib/db/connection";
import { creators, user } from "../src/lib/db/schema";
import { sql } from "drizzle-orm";

async function migrateUserCreatorLink() {
  console.log("🚀 Starting User-Creator Link Migration...");

  try {
    // Step 1: Add user_id column if it doesn't exist
    console.log("📝 Adding user_id column to creators table...");
    await db.execute(sql`
      ALTER TABLE creators 
      ADD COLUMN IF NOT EXISTS user_id TEXT
    `);

    // Step 2: Count existing creators without user_id
    const orphanedCreators = await db.execute(sql`
      SELECT COUNT(*) as count 
      FROM creators 
      WHERE user_id IS NULL
    `);
    
    const orphanCount = parseInt(String(orphanedCreators[0]?.count || '0'));
    console.log(`📊 Found ${orphanCount} creators without linked users`);

    if (orphanCount > 0) {
      console.log("⚠️  Options for handling orphaned creators:");
      console.log("   1. Leave them as-is (accessible via creator_id)");
      console.log("   2. Create system user and link them");
      console.log("   3. Delete orphaned creators");
      console.log("");
      console.log("💡 For now, leaving them as-is for manual review");
    }

    // Step 3: Add foreign key constraint (optional, can be done later)
    console.log("🔗 Adding foreign key constraint...");
    try {
      await db.execute(sql`
        ALTER TABLE creators 
        ADD CONSTRAINT IF NOT EXISTS fk_creators_user_id 
        FOREIGN KEY (user_id) REFERENCES "user"(id)
      `);
      console.log("✅ Foreign key constraint added successfully");
    } catch (error) {
      console.log("⚠️  Could not add foreign key constraint:", error.message);
      console.log("   This is normal if there are orphaned creators");
    }

    // Step 4: Verify the migration
    const linkedCreators = await db.execute(sql`
      SELECT COUNT(*) as count 
      FROM creators 
      WHERE user_id IS NOT NULL
    `);
    
    const linkedCount = parseInt(String(linkedCreators[0]?.count || '0'));
    console.log(`📊 Migration completed: ${linkedCount} creators linked to users`);

    console.log("✅ Migration completed successfully!");

  } catch (error) {
    console.error("❌ Migration failed:", error);
    process.exit(1);
  }
}

// Helper function to create system user for orphaned creators
async function createSystemUserForOrphans() {
  console.log("👤 Creating system user for orphaned creators...");
  
  try {
    // Insert system user
    await db.execute(sql`
      INSERT INTO "user" (id, name, email, email_verified, created_at, updated_at)
      VALUES ('system-user', 'System User', 'system@earnlayer.app', true, NOW(), NOW())
      ON CONFLICT (id) DO NOTHING
    `);

    // Link orphaned creators to system user
    const result = await db.execute(sql`
      UPDATE creators 
      SET user_id = 'system-user' 
      WHERE user_id IS NULL
    `);

    console.log("✅ System user created and linked to orphaned creators");
    return result;
  } catch (error) {
    console.error("❌ Failed to create system user:", error);
    throw error;
  }
}

// Run migration
if (require.main === module) {
  migrateUserCreatorLink()
    .then(() => process.exit(0))
    .catch(() => process.exit(1));
}

export { migrateUserCreatorLink, createSystemUserForOrphans };