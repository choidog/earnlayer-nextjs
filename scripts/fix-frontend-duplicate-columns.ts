#!/usr/bin/env tsx

import postgres from "postgres";

// Use the production Railway database URL
const connectionString = "postgres://postgres:LRReC.id2wv8Pq6Hz~WgyRVuwpkunEE.@yamabiko.proxy.rlwy.net:18490/railway";

console.log("🔧 Connecting to PRODUCTION Railway database...");
const sql = postgres(connectionString, { prepare: false });

async function fixDuplicateColumns() {
  try {
    console.log("🔍 Checking current verification table structure...");

    // Check current structure
    const currentStructure = await sql`
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_name = 'verification' AND table_schema = 'public'
      ORDER BY ordinal_position;
    `;

    console.log("📋 Current verification table structure:");
    console.table(currentStructure);

    // Check if duplicate columns exist
    const duplicateColumns = currentStructure.filter(col =>
      ['expiresAt', 'createdAt', 'updatedAt'].includes(col.column_name)
    );

    if (duplicateColumns.length === 0) {
      console.log("✅ No duplicate camelCase columns found. Database is already clean.");
      return;
    }

    console.log(`⚠️ Found ${duplicateColumns.length} duplicate camelCase columns to remove:`);
    duplicateColumns.forEach(col => console.log(`  - ${col.column_name}`));

    console.log("🧹 Removing duplicate camelCase columns...");

    // Remove duplicate columns
    await sql`ALTER TABLE "verification" DROP COLUMN IF EXISTS "expiresAt"`;
    console.log("✅ Dropped expiresAt column");

    await sql`ALTER TABLE "verification" DROP COLUMN IF EXISTS "createdAt"`;
    console.log("✅ Dropped createdAt column");

    await sql`ALTER TABLE "verification" DROP COLUMN IF EXISTS "updatedAt"`;
    console.log("✅ Dropped updatedAt column");

    // Ensure expires_at is NOT NULL as required by Better Auth
    console.log("🔧 Setting expires_at as NOT NULL...");
    await sql`ALTER TABLE "verification" ALTER COLUMN "expires_at" SET NOT NULL`;
    console.log("✅ Set expires_at as NOT NULL");

    // Verify final structure
    console.log("🔍 Checking final verification table structure...");
    const finalStructure = await sql`
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_name = 'verification' AND table_schema = 'public'
      ORDER BY ordinal_position;
    `;

    console.log("📋 Final verification table structure:");
    console.table(finalStructure);

    console.log("✅ Database column fix completed successfully!");
    console.log("🎯 Better Auth should now use the snake_case columns with proper field mapping");

  } catch (error) {
    console.error("❌ Error fixing duplicate columns:", error);
    throw error;
  } finally {
    await sql.end();
  }
}

// Run the fix
fixDuplicateColumns()
  .then(() => {
    console.log("🚀 Migration completed successfully");
    process.exit(0);
  })
  .catch((error) => {
    console.error("💥 Migration failed:", error);
    process.exit(1);
  });