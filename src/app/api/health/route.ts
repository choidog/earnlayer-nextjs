import { NextResponse } from "next/server";

export async function GET() {
  try {
    // Test OpenAI API key presence
    const hasOpenAI = !!process.env.OPENAI_API_KEY;

    // Test database connection (non-blocking)
    let databaseStatus = "unknown";
    try {
      const { db } = await import("@/lib/db/connection");
      const { sql } = await import("drizzle-orm");
      await db.execute(sql`SELECT 1`);
      databaseStatus = "connected";
    } catch (dbError) {
      console.warn("Database health check failed:", dbError instanceof Error ? dbError.message : "Unknown error");
      databaseStatus = "disconnected";
    }

    return NextResponse.json({
      status: "healthy",
      timestamp: new Date().toISOString(),
      services: {
        database: databaseStatus,
        openai: hasOpenAI ? "configured" : "missing",
        mcp_server: "available"
      },
      endpoints: {
        api: "/api/*",
        mcp: "/api/mcp/server",
        auth: "/api/auth/*"
      },
      version: "1.0.0"
    });

  } catch (error) {
    return NextResponse.json({
      status: "unhealthy",
      error: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString()
    }, { status: 503 });
  }
}

export async function POST(request: Request) {
  try {
    const body = await request.json().catch(() => ({}));

    if (body.action === 'seed-demo-ads') {
      console.log('🌱 Seeding demo ads...');

      // Import database connection
      const { db } = await import("@/lib/db/connection");
      const { sql } = await import("drizzle-orm");

      // Enable vector extension
      try {
        await db.execute(sql`CREATE EXTENSION IF NOT EXISTS vector`);
        console.log('✅ Vector extension enabled');
      } catch (error) {
        console.log('⚠️ Vector extension already exists or failed');
      }

      // Clean existing demo data
      await db.execute(sql`DELETE FROM ads WHERE title LIKE '[DEMO]%'`);
      await db.execute(sql`DELETE FROM ad_campaigns WHERE name LIKE '[DEMO]%'`);

      // Create demo campaign
      const crypto = await import("crypto");
      const campaignId = crypto.randomUUID();

      await db.execute(sql`
        INSERT INTO ad_campaigns (
          id, advertiser_id, name, start_date, end_date,
          budget, status, created_at, updated_at
        ) VALUES (
          ${campaignId},
          ${crypto.randomUUID()},
          '[DEMO] Creator Tools',
          ${new Date()},
          ${new Date(Date.now() + 365 * 24 * 60 * 60 * 1000)},
          10000,
          'active',
          ${new Date()},
          ${new Date()}
        )
      `);

      // Create demo ads
      const demoAds = [
        { title: '[DEMO] Notion - All-in-one workspace', url: 'https://notion.so', content: 'Organize your life and work in one place.' },
        { title: '[DEMO] Canva Pro - Design made easy', url: 'https://canva.com/pro', content: 'Create stunning visuals with professional templates.' },
        { title: '[DEMO] Loom - Screen recording', url: 'https://loom.com', content: 'Record and share video messages instantly.' },
        { title: '[DEMO] Vercel - Deploy with confidence', url: 'https://vercel.com', content: 'The platform for frontend developers.' },
        { title: '[DEMO] Stripe - Online payments', url: 'https://stripe.com', content: 'Accept payments and manage your business online.' },
      ];

      for (const ad of demoAds) {
        await db.execute(sql`
          INSERT INTO ads (
            id, campaign_id, title, target_url, ad_type,
            pricing_model, content, status, created_at, updated_at
          ) VALUES (
            ${crypto.randomUUID()},
            ${campaignId},
            ${ad.title},
            ${ad.url},
            'hyperlink',
            'cpm',
            ${ad.content},
            'active',
            ${new Date()},
            ${new Date()}
          )
        `);
      }

      // Verify results
      const campaignCount = await db.execute(sql`SELECT COUNT(*) as count FROM ad_campaigns WHERE name LIKE '[DEMO]%'`);
      const adCount = await db.execute(sql`SELECT COUNT(*) as count FROM ads WHERE title LIKE '[DEMO]%'`);

      return NextResponse.json({
        success: true,
        message: "Demo ads seeded successfully",
        created: {
          campaigns: campaignCount[0]?.count || 0,
          ads: adCount[0]?.count || 0
        },
        timestamp: new Date().toISOString(),
      });
    }

    return NextResponse.json({
      error: "Invalid action. Use {\"action\":\"seed-demo-ads\"}"
    }, { status: 400 });

  } catch (error) {
    console.error("❌ Seeding error:", error);
    return NextResponse.json({
      status: "error",
      error: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString()
    }, { status: 500 });
  }
}