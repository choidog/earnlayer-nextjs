import { NextRequest, NextResponse } from "next/server";
import { adServingService } from "@/lib/services/ad-serving";
import { db } from "@/lib/db/connection";
import { chatSessions } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

export async function GET(
  request: NextRequest,
  { params }: { params: { sessionId: string } }
) {
  try {
    const sessionId = params.sessionId;
    const { searchParams } = new URL(request.url);
    const placement = searchParams.get('placement') || 'sidebar';
    const adType = searchParams.get('ad_type') || 'banner';
    const limit = parseInt(searchParams.get('limit') || '1');
    const similarityThreshold = parseFloat(searchParams.get('threshold') || '0.25');

    // Verify session exists and get creator info
    const session = await db
      .select()
      .from(chatSessions)
      .where(eq(chatSessions.id, sessionId))
      .limit(1);

    if (session.length === 0) {
      return NextResponse.json(
        { error: "Session not found" },
        { status: 404 }
      );
    }

    const sessionData = session[0];
    if (!sessionData.creatorId) {
      return NextResponse.json(
        { error: "Creator not found for session" },
        { status: 400 }
      );
    }

    // Check display ad timing
    const timingResult = await adServingService.getDisplayAdTiming(
      sessionId,
      similarityThreshold
    );

    if (!timingResult.shouldShow) {
      return NextResponse.json({
        ads: [],
        session_id: sessionId,
        placement: placement,
        reason: timingResult.reason,
        should_show: false,
        ads_available: timingResult.adsAvailable,
        threshold_used: timingResult.thresholdUsed,
      });
    }

    // Serve contextual ads based on recent conversation
    const adResult = await adServingService.serveConversationAds(sessionId, {
      creatorId: sessionData.creatorId,
      sessionId,
      adType: adType as any,
      placement: placement as any,
      limit,
      similarityThreshold,
      contextualMessages: 10,
    });

    // Transform ads for frontend
    const formattedAds = adResult.ads.map(ad => ({
      id: ad.id,
      title: ad.title,
      content: ad.content,
      target_url: ad.targetUrl,
      ad_type: ad.adType,
      placement: ad.placement,
      similarity: ad.similarity,
      impression_id: ad.impressionId,
      metadata: ad.metadata,
    }));

    return NextResponse.json({
      ads: formattedAds,
      session_id: sessionId,
      placement: placement,
      reason: adResult.reason,
      should_show: true,
      total_available: adResult.totalAvailable,
      average_similarity: adResult.averageSimilarity,
      threshold_used: similarityThreshold,
    });

  } catch (error) {
    console.error("Error serving display ad:", error);
    return NextResponse.json(
      { 
        error: "Failed to serve display ad",
        ads: [],
        session_id: params.sessionId,
        should_show: false,
        reason: "Internal server error"
      },
      { status: 500 }
    );
  }
}

// Handle impression tracking via POST
export async function POST(
  request: NextRequest,
  { params }: { params: { sessionId: string } }
) {
  try {
    const body = await request.json();
    const { ad_id, impression_id, event_type = 'impression' } = body;

    if (!ad_id || !impression_id) {
      return NextResponse.json(
        { error: "ad_id and impression_id are required" },
        { status: 400 }
      );
    }

    if (event_type === 'click') {
      // Record click
      const clickId = await adServingService.recordClick(impression_id, {
        session_id: params.sessionId,
        timestamp: new Date().toISOString(),
        user_agent: request.headers.get('user-agent') || undefined,
      });

      return NextResponse.json({
        success: true,
        event_type: 'click',
        click_id: clickId,
        impression_id: impression_id,
      });
    }

    // For now, impressions are recorded when ads are served
    // This endpoint could be used for additional impression events
    return NextResponse.json({
      success: true,
      event_type: 'impression',
      impression_id: impression_id,
    });

  } catch (error) {
    console.error("Error tracking ad event:", error);
    return NextResponse.json(
      { error: "Failed to track ad event" },
      { status: 500 }
    );
  }
}