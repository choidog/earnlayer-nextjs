#!/usr/bin/env tsx

import { db } from "../src/lib/db/connection";
import { sql } from "drizzle-orm";

console.log("🧹 Cleaning up Better Auth tables...");
console.log("⚠️  This will permanently delete Better Auth tables!");
console.log("   Make sure frontend-auth migration was successful before proceeding.");

async function cleanupBetterAuth() {
  try {
    console.log("📋 Dropping Better Auth tables...");

    // Drop Better Auth tables in correct order (handle foreign keys)
    await db.execute(sql`DROP TABLE IF EXISTS "session" CASCADE;`);
    await db.execute(sql`DROP TABLE IF EXISTS "account" CASCADE;`);
    await db.execute(sql`DROP TABLE IF EXISTS "verification" CASCADE;`);
    await db.execute(sql`DROP TABLE IF EXISTS "apikey" CASCADE;`);
    await db.execute(sql`DROP TABLE IF EXISTS "user" CASCADE;`);
    await db.execute(sql`DROP TABLE IF EXISTS "verification_token" CASCADE;`);

    console.log("✅ Better Auth tables removed successfully");

    console.log("🎉 Cleanup completed!");
    console.log("Your database now uses the frontend-auth schema exclusively.");

  } catch (error) {
    console.error("❌ Cleanup failed:", error);
    throw error;
  }
}

// Run cleanup
cleanupBetterAuth()
  .then(() => {
    console.log("Cleanup completed successfully");
    process.exit(0);
  })
  .catch((error) => {
    console.error("Cleanup failed:", error);
    process.exit(1);
  });