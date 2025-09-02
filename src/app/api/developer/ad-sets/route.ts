import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { ads, adCampaigns } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";
import { z } from "zod";

// Ad Preview Schema
const adPreviewSchema = z.object({
  id: z.string(),
  title: z.string(),
  description: z.string(),
  ad_type: z.string(),
  image_url: z.string().nullable().optional(),
});

// Ad Set Response Schema
const adSetResponseSchema = z.object({
  id: z.string(),
  name: z.string(),
  description: z.string().nullable().optional(),
  ad_count: z.number(),
  is_public: z.boolean(),
  is_system: z.boolean(),
  sample_ads: z.array(adPreviewSchema).max(4),
  created_at: z.string(),
});

// Ad Set Create Request Schema
const adSetCreateRequestSchema = z.object({
  name: z.string().max(100),
  description: z.string().max(500).optional(),
  ad_ids: z.array(z.string().uuid()).min(1).max(50),
});

export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const creatorId = searchParams.get('creator_id');
    const includePublic = searchParams.get('include_public') !== 'false';

    if (!creatorId) {
      return NextResponse.json(
        { error: "Creator ID is required" },
        { status: 400 }
      );
    }

    // For now, we'll create virtual ad sets based on ad types since we don't have
    // a dedicated ad_sets table yet. This gives us the structure we need.
    
    // Get ads grouped by type to create virtual ad sets
    const adsByType = await db
      .select({
        ad_type: ads.adType,
        ad_count: sql<number>`count(*)`,
        sample_ads: sql<any>`json_agg(
          json_build_object(
            'id', ${ads.id},
            'title', ${ads.title},
            'description', ${ads.content},
            'ad_type', ${ads.adType},
            'image_url', null
          )
        )`,
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

    // Transform into ad sets format
    const adSets = adsByType.map((group, index) => ({
      id: `system-${group.ad_type}-${index}`,
      name: `${group.ad_type.charAt(0).toUpperCase() + group.ad_type.slice(1)} Ads`,
      description: `All ${group.ad_type} ads in the system`,
      ad_count: group.ad_count,
      is_public: true,
      is_system: true,
      sample_ads: Array.isArray(group.sample_ads) 
        ? group.sample_ads.slice(0, 4) 
        : [],
      created_at: new Date().toISOString(),
    }));

    console.log('✅ [Ad Sets] Returning virtual ad sets:', {
      count: adSets.length,
      types: adSets.map(set => set.name)
    });

    return NextResponse.json(adSets);

  } catch (error) {
    console.error("Error fetching ad sets:", error);
    return NextResponse.json(
      { error: "Failed to fetch ad sets" },
      { status: 500 }
    );
  }
}

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

    const body = await request.json();
    const validatedData = adSetCreateRequestSchema.parse(body);

    // Validate that all ad IDs exist and are accessible
    const validAds = await db
      .select({
        id: ads.id,
        title: ads.title,
        description: ads.content,
        ad_type: ads.adType,
      })
      .from(ads)
      .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
      .where(
        and(
          sql`${ads.id} = ANY(${validatedData.ad_ids})`,
          eq(ads.status, "active"),
          eq(adCampaigns.status, "active")
        )
      );

    if (validAds.length !== validatedData.ad_ids.length) {
      return NextResponse.json(
        { error: "Some ad IDs are invalid or inaccessible" },
        { status: 400 }
      );
    }

    // For now, return a mock response since we don't have ad_sets table yet
    // In a full implementation, you would insert into an ad_sets table
    const newAdSet = {
      id: `custom-${Date.now()}`,
      name: validatedData.name,
      description: validatedData.description || null,
      ad_count: validAds.length,
      is_public: false,
      is_system: false,
      sample_ads: validAds.slice(0, 4).map(ad => ({
        id: ad.id,
        title: ad.title,
        description: ad.description,
        ad_type: ad.ad_type,
        image_url: null
      })),
      created_at: new Date().toISOString(),
    };

    console.log('✅ [Ad Sets] Created custom ad set:', {
      id: newAdSet.id,
      name: newAdSet.name,
      ad_count: newAdSet.ad_count
    });

    return NextResponse.json(newAdSet, { status: 201 });

  } catch (error) {
    console.error("Error creating ad set:", error);
    
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
      { error: "Failed to create ad set" },
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
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    },
  });
}