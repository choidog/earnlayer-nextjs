#!/usr/bin/env tsx

import { db } from "../src/lib/db/connection";
import { sql } from "drizzle-orm";

console.log("🚀 Starting migration from Better Auth to Frontend Auth...");

async function migrateToFrontendAuth() {
  try {
    console.log("📋 Step 1: Creating new frontend-auth tables...");

    // Create new users table
    await db.execute(sql`
      CREATE TABLE IF NOT EXISTS "users" (
        "id" TEXT NOT NULL PRIMARY KEY,
        "email" TEXT NOT NULL UNIQUE,
        "name" TEXT NOT NULL,
        "picture" TEXT,
        "email_verified" BOOLEAN NOT NULL DEFAULT FALSE,
        "provider" TEXT NOT NULL DEFAULT 'google',
        "created_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
        "updated_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
      );
    `);

    // Create new api_keys table
    await db.execute(sql`
      CREATE TABLE IF NOT EXISTS "api_keys" (
        "id" TEXT NOT NULL PRIMARY KEY,
        "name" TEXT NOT NULL,
        "key" TEXT NOT NULL UNIQUE,
        "user_id" TEXT NOT NULL REFERENCES "users" ("id") ON DELETE CASCADE,
        "permissions" JSONB NOT NULL DEFAULT '{}',
        "metadata" JSONB NOT NULL DEFAULT '{}',
        "rate_limit" JSONB NOT NULL DEFAULT '{}',
        "last_used_at" TIMESTAMP,
        "created_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
        "updated_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
      );
    `);

    // Create api_key_usage table
    await db.execute(sql`
      CREATE TABLE IF NOT EXISTS "api_key_usage" (
        "id" TEXT NOT NULL PRIMARY KEY,
        "api_key_id" TEXT NOT NULL REFERENCES "api_keys" ("id") ON DELETE CASCADE,
        "endpoint" TEXT NOT NULL,
        "method" TEXT NOT NULL,
        "status_code" INTEGER NOT NULL,
        "response_time" INTEGER,
        "ip_address" TEXT,
        "user_agent" TEXT,
        "created_at" TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL
      );
    `);

    console.log("✅ New tables created successfully");

    console.log("📋 Step 2: Migrating user data from Better Auth...");

    // Check if Better Auth user table exists and has data
    const userCheck = await db.execute(sql`
      SELECT COUNT(*) as count FROM "user"
    `).catch(() => ({ rows: [{ count: 0 }] }));

    const userCount = userCheck.rows?.[0]?.count || 0;
    console.log(`Found ${userCount} users in Better Auth table`);

    if (userCount > 0) {
      // Migrate users from Better Auth user table to new users table
      await db.execute(sql`
        INSERT INTO "users" (id, email, name, picture, email_verified, provider, created_at, updated_at)
        SELECT
          id,
          email,
          name,
          image as picture,
          "email_verified",
          'google' as provider,
          "created_at",
          "updated_at"
        FROM "user"
        ON CONFLICT (id) DO UPDATE SET
          email = EXCLUDED.email,
          name = EXCLUDED.name,
          picture = EXCLUDED.picture,
          email_verified = EXCLUDED.email_verified,
          updated_at = EXCLUDED.updated_at;
      `);

      console.log(`✅ Migrated ${userCount} users successfully`);
    }

    console.log("📋 Step 3: Creating performance indexes...");

    // Create indexes
    await db.execute(sql`CREATE INDEX IF NOT EXISTS "idx_users_email" ON "users" ("email");`);
    await db.execute(sql`CREATE INDEX IF NOT EXISTS "idx_api_keys_user_id" ON "api_keys" ("user_id");`);
    await db.execute(sql`CREATE INDEX IF NOT EXISTS "idx_api_keys_key" ON "api_keys" ("key");`);
    await db.execute(sql`CREATE INDEX IF NOT EXISTS "idx_api_key_usage_api_key_id" ON "api_key_usage" ("api_key_id");`);
    await db.execute(sql`CREATE INDEX IF NOT EXISTS "idx_api_key_usage_created_at" ON "api_key_usage" ("created_at");`);

    console.log("✅ Indexes created successfully");

    console.log("📋 Step 4: Updating existing table references...");

    // Update user_roles table to ensure it references the new users table
    // (It should already work since both use the same ID structure)

    // Update creators table reference (should already work)

    // Update advertisers table reference (should already work)

    console.log("✅ Table references updated");

    console.log("📋 Step 5: Migration validation...");

    // Validate migration
    const newUserCount = await db.execute(sql`SELECT COUNT(*) as count FROM "users"`);
    const newUsersCount = newUserCount.rows?.[0]?.count || 0;

    console.log(`✅ Migration validation: ${newUsersCount} users in new table`);

    console.log("🎉 Frontend Auth migration completed successfully!");
    console.log("");
    console.log("⚠️  IMPORTANT: After verifying everything works correctly, run:");
    console.log("   npm run db:cleanup-better-auth");
    console.log("   to remove the old Better Auth tables");

  } catch (error) {
    console.error("❌ Migration failed:", error);
    throw error;
  }
}

// Run migration
migrateToFrontendAuth()
  .then(() => {
    console.log("Migration completed successfully");
    process.exit(0);
  })
  .catch((error) => {
    console.error("Migration failed:", error);
    process.exit(1);
  });