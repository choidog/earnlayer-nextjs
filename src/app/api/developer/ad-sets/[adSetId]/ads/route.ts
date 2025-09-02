import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { ads, adCampaigns } from "@/lib/db/schema";
import { eq, and } from "drizzle-orm";

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ adSetId: string }> }
) {
  try {
    const { searchParams } = new URL(request.url);
    const creatorId = searchParams.get('creator_id');
    const { adSetId } = await params;

    if (!creatorId) {
      return NextResponse.json(
        { error: "Creator ID is required" },
        { status: 400 }
      );
    }

    if (!adSetId) {
      return NextResponse.json(
        { error: "Ad Set ID is required" },
        { status: 400 }
      );
    }

    // Parse the virtual ad set ID to determine ad type
    // Format: "system-{ad_type}-{index}" or "custom-{timestamp}"
    let adType = null;
    if (adSetId.startsWith('system-')) {
      const parts = adSetId.split('-');
      if (parts.length >= 2) {
        adType = parts[1];
      }
    }

    if (!adType && !adSetId.startsWith('custom-')) {
      return NextResponse.json(
        { error: "Ad set not found or access denied" },
        { status: 404 }
      );
    }

    let whereCondition;
    if (adType) {
      // System ad set - filter by ad type
      whereCondition = and(
        eq(ads.status, "active"),
        eq(adCampaigns.status, "active"),
        eq(ads.adType, adType)
      );
    } else {
      // Custom ad set - for now, return all ads since we don't have relationships stored
      whereCondition = and(
        eq(ads.status, "active"),
        eq(adCampaigns.status, "active")
      );
    }

    // Get all ads in the ad set
    const adList = await db
      .select({
        id: ads.id,
        title: ads.title,
        description: ads.content,
        ad_type: ads.adType,
        image_url: ads.targetUrl, // Using targetUrl as a placeholder for image_url
      })
      .from(ads)
      .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
      .where(whereCondition)
      .limit(50); // Reasonable limit

    if (adList.length === 0) {
      return NextResponse.json(
        { error: "Ad set not found or access denied" },
        { status: 404 }
      );
    }

    // Transform to expected format
    const adPreviews = adList.map(ad => ({
      id: ad.id,
      title: ad.title,
      description: ad.description,
      ad_type: ad.ad_type,
      image_url: null, // Set to null since we don't have image URLs yet
    }));

    console.log('✅ [Ad Set Details] Returning ads for set:', {
      adSetId,
      adType,
      count: adPreviews.length
    });

    return NextResponse.json(adPreviews);

  } catch (error) {
    console.error("Error fetching ad set ads:", error);
    return NextResponse.json(
      { error: "Failed to fetch ad set ads" },
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