export async function POST() {
  try {
    const { db } = await import("@/lib/db/connection");
    const { adCampaigns, ads } = await import("@/lib/db/schema");
    const crypto = await import("crypto");

    console.log('🎯 [SIMPLE-DEMO] Creating demo ads...');

    // Clean up existing demo data first
    await db.execute(`DELETE FROM ads WHERE title LIKE '[DEMO]%'` as any);
    await db.execute(`DELETE FROM ad_campaigns WHERE name LIKE '[DEMO]%'` as any);
    
    // Create one demo campaign
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

    // Create a few demo ads
    const demoAds = [
      { title: '[DEMO] Notion - All-in-one workspace', url: 'https://notion.so', content: 'Organize your life and work in one place.' },
      { title: '[DEMO] Canva Pro - Design made easy', url: 'https://canva.com/pro', content: 'Create stunning visuals with professional templates.' },
      { title: '[DEMO] Loom - Screen recording', url: 'https://loom.com', content: 'Record and share video messages instantly.' },
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

    console.log(`✅ Created ${campaignCount[0]?.count || 0} campaigns and ${adCount[0]?.count || 0} ads`);

    return Response.json({
      success: true,
      message: "Demo ads created successfully",
      created: {
        campaigns: campaignCount[0]?.count || 0,
        ads: adCount[0]?.count || 0
      },
      timestamp: new Date().toISOString(),
    });

  } catch (error) {
    console.error("❌ Error creating demo ads:", error);
    return Response.json({ 
      success: false,
      error: "Failed to create demo ads", 
      message: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString(),
    }, { status: 500 });
  }
}