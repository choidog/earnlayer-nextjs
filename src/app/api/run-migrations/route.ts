import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import fs from "fs";
import path from "path";

export async function POST(request: NextRequest) {
  try {
    console.log("🚀 Running database migrations...");
    
    // Read the migration file
    const migrationPath = path.join(process.cwd(), "drizzle/migrations/0007_create_ads_tables.sql");
    const migrationSQL = fs.readFileSync(migrationPath, "utf8");
    
    console.log("📄 Migration SQL:", migrationSQL);
    
    // Execute the migration
    await db.execute(migrationSQL as any);
    
    console.log("✅ Migration executed successfully");
    
    // Verify tables were created
    const tables = await db.execute(`
      SELECT table_name 
      FROM information_schema.tables 
      WHERE table_schema = 'public' 
      AND table_name IN ('ad_campaigns', 'ads', 'creators')
      ORDER BY table_name;
    ` as any);
    
    console.log("📋 Created tables:", tables);
    
    return NextResponse.json({
      success: true,
      message: "Migration executed successfully",
      tables: tables,
      timestamp: new Date().toISOString(),
    });
    
  } catch (error) {
    console.error("❌ Migration failed:", error);
    return NextResponse.json({
      success: false,
      error: "Migration failed",
      message: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString(),
    }, { status: 500 });
  }
}
