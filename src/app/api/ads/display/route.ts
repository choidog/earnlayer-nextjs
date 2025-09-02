import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { defaultAdRelationship, ads, adCampaigns, chatSessions } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";

const displayAdRequestSchema = z.object({
  conversation_id: z.string().uuid(),
  ad_type: z.string().optional(), // Required for default ads lookup
  context: z.string().optional(),
  placement: z.string().optional(),
  ad_types: z.array(z.string()).optional(),
  metadata: z.record(z.any()).optional(),
});

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const validatedData = displayAdRequestSchema.parse(body);

    // Get creator ID from conversation
    const conversation = await db
      .select({ creatorId: chatSessions.creatorId })
      .from(chatSessions)
      .where(eq(chatSessions.id, validatedData.conversation_id))
      .limit(1);

    if (conversation.length === 0) {
      return NextResponse.json(
        { error: "Conversation not found" },
        { status: 404 }
      );
    }

    const creatorId = conversation[0].creatorId;
    const requestedAdType = validatedData.ad_type || 'banner'; // Default to banner

    // First, try to get creator-specific default ad
    const creatorDefault = await db
      .select({
        ad_id: ads.id,
        title: ads.title,
        description: ads.content,
        url: ads.targetUrl,
        ad_type: ads.adType,
        placement: defaultAdRelationship.placement,
      })
      .from(defaultAdRelationship)
      .innerJoin(ads, eq(defaultAdRelationship.adId, ads.id))
      .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
      .where(
        and(
          eq(defaultAdRelationship.creatorId, creatorId),
          eq(defaultAdRelationship.adType, requestedAdType),
          eq(defaultAdRelationship.isGlobalDefault, false),
          eq(ads.status, "active"),
          eq(adCampaigns.status, "active")
        )
      )
      .limit(1);

    if (creatorDefault.length > 0) {
      const ad = creatorDefault[0];
      const displayAd = {
        ad_id: ad.ad_id,
        title: ad.title,
        description: ad.description,
        url: ad.url,
        ad_type: ad.ad_type,
        placement: ad.placement,
        similarity: 1.0, // Perfect match for default ads
        source: "creator_default",
        impression_id: `imp_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
        image_url: null
      };

      return NextResponse.json({
        ad: displayAd,
        status: "success"
      });
    }

    // Fallback: get any active ad of the requested type
    const fallbackAd = await db
      .select({
        ad_id: ads.id,
        title: ads.title,
        description: ads.content,
        url: ads.targetUrl,
        ad_type: ads.adType,
        placement: ads.placement,
      })
      .from(ads)
      .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
      .where(
        and(
          eq(ads.adType, requestedAdType),
          eq(ads.status, "active"),
          eq(adCampaigns.status, "active")
        )
      )
      .limit(1);

    if (fallbackAd.length > 0) {
      const ad = fallbackAd[0];
      const displayAd = {
        ad_id: ad.ad_id,
        title: ad.title,
        description: ad.description,
        url: ad.url,
        ad_type: ad.ad_type,
        placement: ad.placement,
        similarity: 0.5, // Medium similarity for fallback
        source: "fallback",
        impression_id: `imp_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`,
        image_url: null
      };

      return NextResponse.json({
        ad: displayAd,
        status: "success"
      });
    }

    // No ads available
    return NextResponse.json(
      { error: "No ads available for the requested type" },
      { status: 404 }
    );

  } catch (error) {
    console.error("Error getting display ad:", error);
    
    if (error instanceof z.ZodError) {
      return NextResponse.json(
        { 
          error: "Invalid request data", 
          details: error.errors 
        },
        { status: 400 }
      );
    }

    return NextResponse.json(
      { error: "Failed to get display ad" },
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
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    },
  });
}