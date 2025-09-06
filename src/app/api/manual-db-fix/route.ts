export async function POST() {
  const { db } = await import("@/lib/db/connection");
  try {
    console.log("🔧 Starting manual database schema fix...");
    
    // Step 1: Check current schema
    console.log("📋 Checking current schema...");
    const currentSchema = await db.execute(`
      SELECT table_name, column_name, data_type 
      FROM information_schema.columns 
      WHERE table_name IN ('user', 'account', 'session', 'verification') 
      AND table_schema = 'public'
      ORDER BY table_name, ordinal_position;
    ` as any);
    
    console.log("Current schema:", JSON.stringify(currentSchema, null, 2));
    
    // Step 2: Drop all Better Auth tables (order matters for foreign keys)
    console.log("🗑️ Dropping existing tables...");
    
    await db.execute(`DROP TABLE IF EXISTS "session" CASCADE;` as any);
    console.log("✅ Dropped session table");
    
    await db.execute(`DROP TABLE IF EXISTS "account" CASCADE;` as any);
    console.log("✅ Dropped account table");
    
    await db.execute(`DROP TABLE IF EXISTS "verification" CASCADE;` as any);
    console.log("✅ Dropped verification table");
    
    await db.execute(`DROP TABLE IF EXISTS "user" CASCADE;` as any);
    console.log("✅ Dropped user table");
    
    // Step 3: Create user table with TEXT id
    console.log("🏗️ Creating user table...");
    await db.execute(`
      CREATE TABLE "user" (
        "id" text PRIMARY KEY NOT NULL,
        "name" text NOT NULL,
        "email" text NOT NULL,
        "email_verified" boolean DEFAULT false NOT NULL,
        "image" text,
        "created_at" timestamp DEFAULT now() NOT NULL,
        "updated_at" timestamp DEFAULT now() NOT NULL,
        CONSTRAINT "user_email_unique" UNIQUE("email")
      );
    ` as any);
    console.log("✅ Created user table");
    
    // Step 4: Create account table
    console.log("🏗️ Creating account table...");
    await db.execute(`
      CREATE TABLE "account" (
        "id" text PRIMARY KEY NOT NULL,
        "account_id" text NOT NULL,
        "provider_id" text NOT NULL,
        "user_id" text NOT NULL,
        "access_token" text,
        "refresh_token" text,
        "id_token" text,
        "access_token_expires_at" timestamp,
        "refresh_token_expires_at" timestamp,
        "scope" text,
        "password" text,
        "created_at" timestamp DEFAULT now() NOT NULL,
        "updated_at" timestamp DEFAULT now() NOT NULL,
        CONSTRAINT "account_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "user"("id") ON DELETE CASCADE
      );
    ` as any);
    console.log("✅ Created account table");
    
    // Step 5: Create session table
    console.log("🏗️ Creating session table...");
    await db.execute(`
      CREATE TABLE "session" (
        "id" text PRIMARY KEY NOT NULL,
        "expires_at" timestamp NOT NULL,
        "token" text NOT NULL,
        "created_at" timestamp DEFAULT now() NOT NULL,
        "updated_at" timestamp DEFAULT now() NOT NULL,
        "ip_address" text,
        "user_agent" text,
        "user_id" text NOT NULL,
        CONSTRAINT "session_token_unique" UNIQUE("token"),
        CONSTRAINT "session_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "user"("id") ON DELETE CASCADE
      );
    ` as any);
    console.log("✅ Created session table");
    
    // Step 6: Create verification table (the critical one)
    console.log("🏗️ Creating verification table...");
    await db.execute(`
      CREATE TABLE "verification" (
        "id" text PRIMARY KEY NOT NULL,
        "identifier" text NOT NULL,
        "value" text NOT NULL,
        "expires_at" timestamp NOT NULL,
        "created_at" timestamp DEFAULT now() NOT NULL,
        "updated_at" timestamp DEFAULT now() NOT NULL
      );
    ` as any);
    console.log("✅ Created verification table");
    
    // Step 7: Verify the new schema
    console.log("📋 Verifying new schema...");
    const newSchema = await db.execute(`
      SELECT table_name, column_name, data_type 
      FROM information_schema.columns 
      WHERE table_name IN ('user', 'account', 'session', 'verification') 
      AND table_schema = 'public'
      ORDER BY table_name, ordinal_position;
    ` as any);
    
    console.log("New schema:", JSON.stringify(newSchema, null, 2));
    
    const result = {
      success: true,
      message: "Database schema manually fixed - all ID columns are now TEXT type",
      currentSchema: currentSchema,
      newSchema: newSchema,
      timestamp: new Date().toISOString(),
    };
    
    console.log("🎉 Manual database fix completed successfully!");
    
    return Response.json(result);
    
  } catch (error) {
    console.error("❌ Manual database fix failed:", error);
    return Response.json({ 
      success: false,
      error: "Manual database fix failed", 
      message: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString(),
    }, { status: 500 });
  }
}