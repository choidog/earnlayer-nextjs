export async function POST() {
  try {
    const { db } = await import("@/lib/db/connection");
    
    console.log('🧩 Setting up pgvector database...');
    
    // Step 1: Enable vector extension
    try {
      await db.execute(`CREATE EXTENSION IF NOT EXISTS vector;` as any);
      console.log('✅ pgvector extension enabled');
    } catch (error) {
      console.log('⚠️ Vector extension error (may already exist):', error);
    }
    
    // Step 2: Verify vector extension
    const vectorCheck = await db.execute(`
      SELECT extname, extversion 
      FROM pg_extension 
      WHERE extname = 'vector';
    ` as any);
    
    // Step 3: Check existing tables
    const tablesResult = await db.execute(`
      SELECT table_name 
      FROM information_schema.tables 
      WHERE table_schema = 'public' 
      AND table_name IN ('ad_campaigns', 'ads')
      ORDER BY table_name;
    ` as any);
    
    let demoAdsCreated = false;
    
    if (tablesResult.length >= 2) {
      console.log('📊 Creating demo ads...');
      
      // Clean up existing demo data
      await db.execute(`DELETE FROM ads WHERE title LIKE '[DEMO]%'` as any);
      await db.execute(`DELETE FROM ad_campaigns WHERE name LIKE '[DEMO]%'` as any);
      
      const crypto = await import("crypto");
      
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
      
      demoAdsCreated = true;
      console.log(`✅ Created ${campaignCount[0]?.count || 0} campaigns and ${adCount[0]?.count || 0} ads`);
    }

    return Response.json({
      success: true,
      message: "pgvector database setup completed",
      results: {
        vectorExtension: vectorCheck.length > 0 ? vectorCheck[0] : null,
        tablesFound: tablesResult.map((r: any) => r.table_name),
        demoAdsCreated,
      },
      timestamp: new Date().toISOString(),
    });

  } catch (error) {
    console.error("❌ Setup error:", error);
    return Response.json({ 
      success: false,
      error: "Setup failed", 
      message: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString(),
    }, { status: 500 });
  }
}