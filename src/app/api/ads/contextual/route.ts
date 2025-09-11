import { NextRequest, NextResponse } from "next/server";
import { adServingService } from "@/lib/services/ad-serving";
import { z } from "zod";
import { withApiKey, type ApiKeyValidation, hasPermission } from "@/lib/middleware/api-key";

const contextualRequestSchema = z.object({
  query: z.string().min(1),
  creator_id: z.string().uuid(),
  session_id: z.string().uuid().optional(),
  ad_type: z.enum(["text", "banner", "video", "hyperlink", "popup", "thinking"]).optional(),
  placement: z.enum(["chat_inline", "sidebar", "content_promo", "chat", "default"]).optional(),
  limit: z.number().min(1).max(10).default(3),
  similarity_threshold: z.number().min(0).max(1).default(0.25),
  revenue_weight: z.number().min(0).max(1).default(0.3),
  exclude_ad_ids: z.array(z.string().uuid()).optional(),
});

async function handlePost(request: NextRequest, validation: ApiKeyValidation): Promise<NextResponse> {
  try {
    // Check permissions for ad serving
    if (!hasPermission(validation, 'ads:serve')) {
      return NextResponse.json(
        { error: "Insufficient permissions for ad serving" },
        { status: 403 }
      );
    }

    const body = await request.json();
    const validatedData = contextualRequestSchema.parse(body);

    // Serve contextual ads
    const adResult = await adServingService.serveContextualAds(
      validatedData.query,
      {
        creatorId: validatedData.creator_id,
        sessionId: validatedData.session_id,
        adType: validatedData.ad_type,
        placement: validatedData.placement,
        limit: validatedData.limit,
        similarityThreshold: validatedData.similarity_threshold,
        excludeAdIds: validatedData.exclude_ad_ids,
        revenueWeight: validatedData.revenue_weight,
      }
    );

    // Transform for API response
    const responseAds = adResult.ads.map(ad => ({
      id: ad.id,
      title: ad.title,
      content: ad.content,
      target_url: ad.targetUrl,
      ad_type: ad.adType,
      placement: ad.placement,
      similarity: ad.similarity,
      revenue: ad.revenue,
      impression_id: ad.impressionId,
      metadata: ad.metadata,
    }));

    return NextResponse.json({
      ads: responseAds,
      query: validatedData.query,
      session_id: validatedData.session_id,
      placement: validatedData.placement || "default",
      total_available: adResult.totalAvailable,
      average_similarity: adResult.averageSimilarity,
      reason: adResult.reason,
      served_at: new Date().toISOString(),
    });

  } catch (error) {
    console.error("Error serving contextual ads:", error);
    
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
      { error: "Failed to serve contextual ads" },
      { status: 500 }
    );
  }
}

export const POST = withApiKey(handlePost);

// GET endpoint for quick testing
async function handleGet(request: NextRequest, validation: ApiKeyValidation): Promise<NextResponse> {
  const { searchParams } = new URL(request.url);
  
  const query = searchParams.get('query');
  const creatorId = searchParams.get('creator_id');
  
  if (!query || !creatorId) {
    return NextResponse.json(
      { error: "query and creator_id parameters are required" },
      { status: 400 }
    );
  }

  // Check permissions for ad serving
  if (!hasPermission(validation, 'ads:serve')) {
    return NextResponse.json(
      { error: "Insufficient permissions for ad serving" },
      { status: 403 }
    );
  }

  try {
    const adResult = await adServingService.serveContextualAds(query, {
      creatorId,
      limit: parseInt(searchParams.get('limit') || '3'),
      similarityThreshold: parseFloat(searchParams.get('threshold') || '0.25'),
    });

    return NextResponse.json({
      ads: adResult.ads.map(ad => ({
        id: ad.id,
        title: ad.title,
        content: ad.content,
        similarity: ad.similarity,
        ad_type: ad.adType,
      })),
      total_available: adResult.totalAvailable,
      average_similarity: adResult.averageSimilarity,
      reason: adResult.reason,
    });

  } catch (error) {
    console.error("Error serving contextual ads (GET):", error);
    return NextResponse.json(
      { error: "Failed to serve contextual ads" },
      { status: 500 }
    );
  }
}

export const GET = withApiKey(handleGet);