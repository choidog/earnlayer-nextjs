import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { ads, adCampaigns, chatSessions, creators } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";

/**
 * Developer Ads Queue Endpoint (Simplified)
 * 
 * PRODUCTION MODE (default):
 *   GET /api/developer/ads/queue/{conversationId}
 *   Returns: Empty array (MCP server controls actual ad serving)
 * 
 * DEBUG MODE:
 *   GET /api/developer/ads/queue/{conversationId}?debug=true
 *   Returns: All available display ads for debugging purposes
 * 
 * ADMIN MODE:
 *   GET /api/developer/ads/queue/{conversationId}?admin=true
 *   Returns: All available display ads with debug metadata for admin inspection
 */
export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ conversationId: string }> }
) {
  try {
    console.log("🚀 [ADS] Starting ads queue request...");
    
    const { searchParams } = new URL(request.url);
    console.log("✅ [ADS] URL parsed successfully");
    
    const { conversationId } = await params;
    console.log("✅ [ADS] Params extracted, conversationId:", conversationId);

    if (!conversationId) {
      console.log("❌ [ADS] No conversation ID provided");
      return NextResponse.json(
        { error: "Conversation ID is required" },
        { status: 400 }
      );
    }

    console.log("🔍 [ADS] Getting ads for conversation:", conversationId);

    console.log("📊 [ADS] Starting database query...");
    // Get conversation and automatically resolve creator
    const conversation = await db
      .select({
        sessionId: chatSessions.id,
        creatorId: chatSessions.creatorId,
        creatorName: creators.name,
        creatorUserId: creators.userId
      })
      .from(chatSessions)
      .innerJoin(creators, eq(chatSessions.creatorId, creators.id))
      .where(eq(chatSessions.id, conversationId))
      .limit(1);
    
    console.log("✅ [ADS] Database query completed, results:", conversation.length);

    if (conversation.length === 0) {
      console.log("❌ [ADS] Conversation not found:", conversationId);
      return NextResponse.json(
        { error: "Conversation not found" },
        { status: 404 }
      );
    }

    const { creatorId } = conversation[0];
    console.log("✅ [ADS] Found conversation for creator:", { 
      conversationId, 
      creatorId, 
      creatorName: conversation[0].creatorName 
    });

    // ADMIN/DEBUG MODE: Check if this is an admin/debug request
    const isDebugMode = searchParams.get('debug') === 'true';
    const isAdminMode = searchParams.get('admin') === 'true';
    
    if (isDebugMode || isAdminMode) {
      // Return all available display ads for debugging/admin purposes
      const rawAds = await db
        .select({
          ad_id: ads.id,
          title: ads.title,
          description: ads.content,
          url: ads.targetUrl,
          ad_type: ads.adType,
          placement: ads.placement,
          status: ads.status,
          campaign_status: adCampaigns.status,
        })
        .from(ads)
        .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
        .where(
          and(
            eq(ads.status, "active"),
            eq(adCampaigns.status, "active"),
            sql`${ads.adType} IN ('banner', 'popup', 'video', 'thinking')` // All display ad types
          )
        )
        .limit(20); // Higher limit for admin view

      const displayAds = rawAds.map(ad => ({
        ...ad,
        similarity: 0.0, // Mark as debug data
        source: "debug-database",
        image_url: null,
        debug_info: {
          note: "This is debug/admin data - not from MCP server",
          retrieved_at: new Date().toISOString()
        }
      }));

      console.log(`[Developer Queue] Debug/Admin mode: Returning ${displayAds.length} ads for inspection`);
      return NextResponse.json({ 
        ads: displayAds,
        debug_mode: true,
        note: "These ads are for debugging/admin purposes only and do not represent actual served ads"
      });
    }

    // PRODUCTION MODE: Return empty array since MCP server handles actual ad serving
    const displayAds: any[] = [];
    console.log(`[Developer Queue] Production mode: Returning ${displayAds.length} ads (MCP server controls ad serving)`);

    return NextResponse.json({ ads: displayAds });

  } catch (error) {
    console.error("❌ [ADS] Error getting ads queue:", error);
    console.error("❌ [ADS] Error details:", {
      message: error.message,
      stack: error.stack,
      conversationId
    });
    return NextResponse.json(
      { 
        error: "Failed to get ads queue",
        debug: process.env.NODE_ENV === 'development' ? {
          message: error.message,
          conversationId
        } : undefined
      },
      { status: 500 }
    );
  }
}

// Handle preflight requests
export async function OPTIONS() {
  return new NextResponse(null, {
    status: 200,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    },
  });
}