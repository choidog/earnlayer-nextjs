import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { sql } from "drizzle-orm";

export async function GET(request: NextRequest) {
  try {
    // Test database connection
    let dbHealthy = false;
    let activeAdsCount = 0;
    let activeCampaignsCount = 0;

    try {
      await db.execute(sql`SELECT 1`);
      dbHealthy = true;
      
      // Count active ads using Drizzle ORM approach
      const adsResult = await db.execute(sql`
        SELECT COUNT(*) as count 
        FROM ads 
        WHERE status = 'active' AND deleted_at IS NULL
      `);
      activeAdsCount = parseInt(String(adsResult[0]?.count || '0'));

      // Count active campaigns
      const campaignsResult = await db.execute(sql`
        SELECT COUNT(*) as count 
        FROM ad_campaigns 
        WHERE status = 'active' AND deleted_at IS NULL
      `);
      activeCampaignsCount = parseInt(String(campaignsResult[0]?.count || '0'));
      
    } catch (dbError) {
      console.error('Database health check failed:', dbError);
      dbHealthy = false;
    }

    // Test OpenAI API connection
    let openaiHealthy = false;
    try {
      if (process.env.OPENAI_API_KEY) {
        const response = await fetch('https://api.openai.com/v1/models', {
          method: 'GET',
          headers: {
            'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`,
            'Content-Type': 'application/json',
          },
        });
        openaiHealthy = response.ok;
      }
    } catch (error) {
      console.error('OpenAI health check failed:', error);
      openaiHealthy = false;
    }

    const status = dbHealthy && openaiHealthy ? 'healthy' : 'degraded';

    return NextResponse.json({
      status: status,
      timestamp: new Date().toISOString(),
      server: 'EarnLayer MCP Server',
      version: '1.0.0',
      transport: 'http',
      checks: {
        database: {
          status: dbHealthy ? 'healthy' : 'unhealthy',
          active_ads: activeAdsCount,
          active_campaigns: activeCampaignsCount
        },
        openai: {
          status: openaiHealthy ? 'healthy' : 'unhealthy',
          api_key_configured: !!process.env.OPENAI_API_KEY
        }
      },
      endpoints: {
        main: '/api/mcp/server',
        stream: '/api/mcp/stream',
        health: '/api/mcp/health'
      },
      tools: [
        'earnlayer_content_ads_search'
      ]
    });

  } catch (error) {
    console.error('Health check error:', error);
    return NextResponse.json({
      status: 'unhealthy',
      timestamp: new Date().toISOString(),
      error: String(error)
    }, { status: 500 });
  }
}

// Handle preflight requests
export async function OPTIONS() {
  return new NextResponse(null, {
    status: 200,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
    },
  });
}