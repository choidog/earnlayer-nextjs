export async function POST(request: Request) {
  const { db } = await import("@/lib/db/connection");
  try {
    const body = await request.json().catch(() => ({}));
    const action = body.action;
    
    if (action === 'enable-vector') {
      console.log("🧩 Enabling pgvector extension...");
      
      try {
        await db.execute(`CREATE EXTENSION IF NOT EXISTS vector;` as any);
        console.log("✅ pgvector extension enabled successfully!");
        
        const result = await db.execute(`
          SELECT extname, extversion 
          FROM pg_extension 
          WHERE extname = 'vector';
        ` as any);
        
        return Response.json({
          success: true,
          message: "pgvector extension enabled successfully",
          extension: result.length > 0 ? result[0] : null,
          timestamp: new Date().toISOString(),
        });
      } catch (error) {
        console.error("❌ Error enabling pgvector extension:", error);
        return Response.json({ 
          success: false,
          error: "Failed to enable pgvector extension", 
          message: error instanceof Error ? error.message : "Unknown error",
        }, { status: 500 });
      }
      
    } else if (action === 'create-demo-ads') {
      console.log('🎯 Creating demo ads...');
      
      const crypto = await import("crypto");
      
      // Clean up existing demo data
      await db.execute(`DELETE FROM ads WHERE title LIKE '[DEMO]%'` as any);
      await db.execute(`DELETE FROM ad_campaigns WHERE name LIKE '[DEMO]%'` as any);
      
      // Create demo campaign
      const campaignId = crypto.randomUUID();
      await db.execute(`
        INSERT INTO ad_campaigns (
          id, advertiser_id, name, start_date, end_date, 
          budget, status, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      ` as any, [
        campaignId,
        crypto.randomUUID(),
        '[DEMO] Creator Tools',
        new Date(),
        new Date(Date.now() + 365 * 24 * 60 * 60 * 1000),
        10000,
        'active',
        new Date(),
        new Date()
      ]);

      // Create demo ads
      const demoAds = [
        { title: '[DEMO] Notion - All-in-one workspace', url: 'https://notion.so', content: 'Organize your life and work in one place.' },
        { title: '[DEMO] Canva Pro - Design made easy', url: 'https://canva.com/pro', content: 'Create stunning visuals with professional templates.' },
        { title: '[DEMO] Loom - Screen recording', url: 'https://loom.com', content: 'Record and share video messages instantly.' },
        { title: '[DEMO] Vercel - Deploy with confidence', url: 'https://vercel.com', content: 'The platform for frontend developers.' },
        { title: '[DEMO] Stripe - Online payments', url: 'https://stripe.com', content: 'Accept payments and manage your business online.' },
      ];

      for (const ad of demoAds) {
        await db.execute(`
          INSERT INTO ads (
            id, campaign_id, title, target_url, ad_type, 
            pricing_model, content, status, created_at, updated_at
          ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ` as any, [
          crypto.randomUUID(),
          campaignId,
          ad.title,
          ad.url,
          'hyperlink',
          'cpm',
          ad.content,
          'active',
          new Date(),
          new Date()
        ]);
      }

      // Verify results
      const campaignCount = await db.execute(`SELECT COUNT(*) as count FROM ad_campaigns WHERE name LIKE '[DEMO]%'` as any);
      const adCount = await db.execute(`SELECT COUNT(*) as count FROM ads WHERE title LIKE '[DEMO]%'` as any);

      return Response.json({
        success: true,
        message: "Demo ads created successfully",
        created: {
          campaigns: campaignCount[0]?.count || 0,
          ads: adCount[0]?.count || 0
        },
        timestamp: new Date().toISOString(),
      });
    }
    
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