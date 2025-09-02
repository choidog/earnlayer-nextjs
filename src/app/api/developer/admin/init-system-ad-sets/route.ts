import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { ads, adCampaigns } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";

export async function POST(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const creatorId = searchParams.get('creator_id');

    if (!creatorId) {
      return NextResponse.json(
        { error: "Creator ID is required" },
        { status: 400 }
      );
    }

    // For demo purposes, any authenticated user can run this
    // In production, this would require admin privileges

    console.log('🔧 [Admin] Initializing system ad sets...');

    // Get statistics on existing ads to create virtual ad sets
    const adTypeStats = await db
      .select({
        ad_type: ads.adType,
        count: sql<number>`count(*)`,
        campaign_count: sql<number>`count(DISTINCT ${ads.campaignId})`,
      })
      .from(ads)
      .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
      .where(
        and(
          eq(ads.status, "active"),
          eq(adCampaigns.status, "active")
        )
      )
      .groupBy(ads.adType);

    // Get sample ads for each type
    const sampleAdsByType = {};
    for (const stat of adTypeStats) {
      const sampleAds = await db
        .select({
          id: ads.id,
          title: ads.title,
          content: ads.content,
          adType: ads.adType,
        })
        .from(ads)
        .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
        .where(
          and(
            eq(ads.status, "active"),
            eq(adCampaigns.status, "active"),
            eq(ads.adType, stat.ad_type)
          )
        )
        .limit(5);

      sampleAdsByType[stat.ad_type] = sampleAds;
    }

    // Create virtual system ad sets (these would be stored in an ad_sets table in full implementation)
    const systemAdSets = adTypeStats.map(stat => ({
      id: `system-${stat.ad_type}`,
      name: `System ${stat.ad_type.charAt(0).toUpperCase() + stat.ad_type.slice(1)} Ads`,
      description: `All ${stat.ad_type} ads available in the system`,
      ad_count: stat.count,
      campaign_count: stat.campaign_count,
      is_public: true,
      is_system: true,
      created_at: new Date().toISOString(),
      sample_ads: sampleAdsByType[stat.ad_type]?.map(ad => ({
        id: ad.id,
        title: ad.title,
        description: ad.content,
        ad_type: ad.adType,
      })) || [],
    }));

    const initializationResult = {
      message: "System ad sets initialized successfully",
      summary: {
        total_ad_sets_created: systemAdSets.length,
        total_ads_processed: adTypeStats.reduce((sum, stat) => sum + stat.count, 0),
        total_campaigns_involved: adTypeStats.reduce((sum, stat) => sum + stat.campaign_count, 0),
        ad_sets_by_type: systemAdSets.map(set => ({
          type: set.name,
          ad_count: set.ad_count,
          sample_count: set.sample_ads.length,
        })),
      },
      ad_sets: systemAdSets,
      initialized_at: new Date().toISOString(),
      initialized_by: creatorId,
    };

    console.log('✅ [Admin] System ad sets initialized:', {
      adSetsCount: systemAdSets.length,
      totalAds: initializationResult.summary.total_ads_processed,
      types: systemAdSets.map(s => s.name)
    });

    return NextResponse.json(initializationResult);

  } catch (error) {
    console.error("Error initializing system ad sets:", error);
    return NextResponse.json(
      { error: "Failed to initialize system ad sets" },
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