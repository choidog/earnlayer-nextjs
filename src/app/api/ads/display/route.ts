import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { defaultAdRelationship, ads, adCampaigns, chatSessions } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";
import { z } from "zod";
import { Logger } from "@/lib/logging/logger";
import { successResponse, errorResponse, validationErrorWithSchema } from "@/lib/api/response";
import { NotFoundError, DatabaseError } from "@/lib/api/errors";

const displayAdRequestSchema = z.object({
  conversation_id: z.string().uuid(),
  ad_type: z.string().optional(), // Required for default ads lookup
  context: z.string().optional(),
  placement: z.string().optional(),
  ad_types: z.array(z.string()).optional(),
  metadata: z.record(z.any()).optional(),
});

export async function POST(request: NextRequest) {
  const logger = Logger.fromRequest(request, { endpoint: 'ads/display' });
  
  try {
    const body = await request.json();
    logger.requestStart(body);
    
    const validatedData = displayAdRequestSchema.parse(body);

    // Get creator ID from conversation
    const conversation = await db
      .select({ creatorId: chatSessions.creatorId })
      .from(chatSessions)
      .where(eq(chatSessions.id, validatedData.conversation_id))
      .limit(1);

    if (conversation.length === 0) {
      const error = new NotFoundError(
        "Conversation not found",
        { conversation_id: validatedData.conversation_id },
        "CONVERSATION_NOT_FOUND"
      );
      logger.error("Conversation lookup failed", error);
      return errorResponse(error, logger.context.requestId);
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

    // No ads available - return 200 with empty result for graceful frontend handling
    logger.info("No ads available for requested type", { 
      ad_type: requestedAdType, 
      creator_id: creatorId 
    });
    
    return successResponse({
      ad: null,
      status: "no_ads_available", 
      message: "No ads available for the requested type"
    }, { requestId: logger.context.requestId });

  } catch (error) {
    if (error instanceof z.ZodError) {
      const validationError = validationErrorWithSchema(error, displayAdRequestSchema, logger);
      return errorResponse(validationError, logger.context.requestId);
    }

    if (error instanceof NotFoundError || error instanceof DatabaseError) {
      return errorResponse(error, logger.context.requestId);
    }

    logger.error("Unexpected error in ads display endpoint", error as Error);
    return errorResponse(error as Error, logger.context.requestId);
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