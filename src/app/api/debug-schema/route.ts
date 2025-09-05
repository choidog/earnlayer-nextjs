import { db } from "@/lib/db/connection";

export async function GET() {
  try {
    console.log("🔍 Checking database schema...");
    
    // Check verification table structure
    const verificationSchema = await db.execute(`
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns 
      WHERE table_name = 'verification' AND table_schema = 'public'
      ORDER BY ordinal_position;
    ` as any);
    
    // Check user table structure  
    const userSchema = await db.execute(`
      SELECT column_name, data_type, is_nullable, column_default
      FROM information_schema.columns 
      WHERE table_name = 'user' AND table_schema = 'public'
      ORDER BY ordinal_position;
    ` as any);
    
    // Check all Better Auth tables
    const authTables = await db.execute(`
      SELECT table_name 
      FROM information_schema.tables 
      WHERE table_schema = 'public' 
      AND table_name IN ('user', 'account', 'session', 'verification', 'verification_token')
      ORDER BY table_name;
    ` as any);
    
    // Check applied migrations
    let migrations: any[] = [];
    try {
      migrations = await db.execute(`
        SELECT migration_name, applied_at 
        FROM drizzle_migrations 
        ORDER BY applied_at DESC 
        LIMIT 10;
      ` as any);
    } catch (error) {
      console.log("❌ drizzle_migrations table does not exist");
    }
    
    const result = {
      verificationTable: verificationSchema,
      userTable: userSchema,
      authTables: authTables,
      migrations: migrations,
      timestamp: new Date().toISOString(),
    };
    
    console.log("📋 Database Schema Analysis:", JSON.stringify(result, null, 2));
    
    return Response.json(result);
    
  } catch (error) {
    console.error("❌ Database schema check failed:", error);
    return Response.json({ 
      error: "Database schema check failed", 
      message: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString(),
    }, { status: 500 });
  }
}