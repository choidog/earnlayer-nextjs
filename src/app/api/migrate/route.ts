import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { sql } from "drizzle-orm";

// Temporary migration endpoint - REMOVE AFTER MIGRATION
export async function POST(request: NextRequest) {
  try {
    // Security check - only allow in development or with secret key
    const authHeader = request.headers.get('authorization');
    const expectedSecret = process.env.MIGRATION_SECRET || 'demo-migration-secret';
    
    if (authHeader !== `Bearer ${expectedSecret}`) {
      return NextResponse.json(
        { error: "Unauthorized" },
        { status: 401 }
      );
    }

    console.log("🚀 Starting User-Creator Link Migration...");

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

    // Step 3: Try to add foreign key constraint
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
    }

    // Step 4: Verify the migration
    const linkedCreators = await db.execute(sql`
      SELECT COUNT(*) as count 
      FROM creators 
      WHERE user_id IS NOT NULL
    `);
    
    const linkedCount = parseInt(String(linkedCreators[0]?.count || '0'));
    
    const result = {
      success: true,
      message: "Migration completed successfully!",
      stats: {
        orphaned_creators: orphanCount,
        linked_creators: linkedCount,
        total_creators: orphanCount + linkedCount
      }
    };

    console.log("✅ Migration completed:", result);
    
    return NextResponse.json(result);

  } catch (error) {
    console.error("❌ Migration failed:", error);
    return NextResponse.json(
      { 
        success: false,
        error: "Migration failed", 
        details: String(error) 
      },
      { status: 500 }
    );
  }
}