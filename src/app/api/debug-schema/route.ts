export async function GET() {
  const { db } = await import("@/lib/db/connection");
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
    
    // Check pgvector extension
    let vectorExtension: any[] = [];
    try {
      vectorExtension = await db.execute(`
        SELECT extname, extversion 
        FROM pg_extension 
        WHERE extname = 'vector';
      ` as any);
    } catch (error) {
      console.log("❌ Could not check vector extension:", error);
    }
    
    const result = {
      verificationTable: verificationSchema,
      userTable: userSchema,
      authTables: authTables,
      migrations: migrations,
      vectorExtension: vectorExtension,
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

export async function POST(request: Request) {
  const { db } = await import("@/lib/db/connection");
  
  try {
    const body = await request.json();
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
      
      // First, ensure tables exist by running migration
      try {
        console.log('🚀 Ensuring tables exist...');
        const fs = await import("fs");
        const path = await import("path");
        
        const migrationPath = path.join(process.cwd(), "drizzle/migrations/0007_create_ads_tables.sql");
        const migrationSQL = fs.readFileSync(migrationPath, "utf8");
        
        console.log("📄 Executing migration SQL...");
        await db.execute(migrationSQL as any);
        console.log("✅ Tables created/verified");
      } catch (error) {
        console.log("⚠️ Migration error (tables might already exist):", error);
      }
      
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
      
    } else if (action === 'run-migrations') {
      console.log('🚀 Running database migrations...');
      
      // Read and execute the migration file
      const fs = await import("fs");
      const path = await import("path");
      
      const migrationPath = path.join(process.cwd(), "drizzle/migrations/0007_create_ads_tables.sql");
      const migrationSQL = fs.readFileSync(migrationPath, "utf8");
      
      console.log("📄 Executing migration SQL...");
      await db.execute(migrationSQL as any);
      
      // Verify tables were created
      const tables = await db.execute(`
        SELECT table_name 
        FROM information_schema.tables 
        WHERE table_schema = 'public' 
        AND table_name IN ('ad_campaigns', 'ads', 'creators')
        ORDER BY table_name;
      ` as any);
      
      return Response.json({
        success: true,
        message: "Migration executed successfully",
        tables: tables,
        timestamp: new Date().toISOString(),
      });
      
    } else {
      return Response.json({
        error: "Invalid action. Use 'enable-vector', 'create-demo-ads', or 'run-migrations'"
      }, { status: 400 });
    }
    
  } catch (error) {
    console.error("❌ Error in POST operation:", error);
    return Response.json({ 
      success: false,
      error: "Operation failed", 
      message: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString(),
    }, { status: 500 });
  }
}