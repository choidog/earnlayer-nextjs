import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { ads, adCampaigns, chatSessions, defaultAdRelationship } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";
import { z } from "zod";

// Default Ad Assignment Schema
const defaultAdAssignmentSchema = z.object({
  ad_type: z.enum(['popup', 'banner', 'thinking', 'video', 'hyperlink']),
  placement: z.string(),
  current_ad: z.object({
    id: z.string(),
    title: z.string(),
    description: z.string(),
    ad_type: z.string(),
    image_url: z.string().nullable().optional(),
  }).nullable().optional(),
  alternatives: z.array(z.object({
    id: z.string(),
    title: z.string(),
    description: z.string(),
    ad_type: z.string(),
    image_url: z.string().nullable().optional(),
  })).max(10).default([]),
});

// Default Ad Update Request Schema
const defaultAdUpdateRequestSchema = z.object({
  assignments: z.array(z.object({
    ad_type: z.string(),
    placement: z.string(),
    ad_id: z.string().uuid(),
  })).min(1),
});

export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const creatorId = searchParams.get('creator_id');
    const conversationId = searchParams.get('conversation_id');

    if (!creatorId) {
      return NextResponse.json(
        { error: "Creator ID is required" },
        { status: 400 }
      );
    }

    let defaultAdsResponse = {};

    // If conversation_id is provided, try to get contextual ads from queue first
    if (conversationId) {
      try {
        // Validate conversation_id format and ownership
        const conversation = await db
          .select()
          .from(chatSessions)
          .where(
            and(
              eq(chatSessions.id, conversationId),
              eq(chatSessions.creatorId, creatorId)
            )
          )
          .limit(1);

        if (conversation.length > 0) {
          // Get ads from active campaigns grouped by type
          const contextualAds = await db
            .select({
              ad_id: ads.id,
              ad_type: ads.adType,
              placement: ads.placement,
              title: ads.title,
              description: ads.content,
              url: ads.targetUrl,
            })
            .from(ads)
            .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
            .where(
              and(
                eq(ads.status, "active"),
                eq(adCampaigns.status, "active"),
                sql`${ads.adType} IN ('thinking', 'banner', 'popup', 'video')`
              )
            )
            .orderBy(ads.adType, sql`RANDOM()`)
            .limit(20);

          // Group ads by type and take the best one for each type
          const adsByType = {};
          for (const ad of contextualAds) {
            const adType = ad.ad_type;
            if (!adsByType[adType]) {
              adsByType[adType] = {
                ad_type: adType,
                placement: ad.placement,
                current_ad: {
                  id: ad.ad_id,
                  title: ad.title,
                  description: ad.description,
                  ad_type: adType,
                  image_url: null,
                },
                alternatives: [],
                source: "queue",
              };
            } else if (adsByType[adType].alternatives.length < 5) {
              adsByType[adType].alternatives.push({
                id: ad.ad_id,
                title: ad.title,
                description: ad.description,
                ad_type: adType,
                image_url: null,
              });
            }
          }

          defaultAdsResponse = adsByType;
        }
      } catch (error) {
        console.error("Error getting contextual ads:", error);
        // Continue to fallback ads
      }
    }

    // Get creator-specific default ads from the database for missing ad types
    const adTypes = ['thinking', 'banner', 'popup', 'video'];
    for (const adType of adTypes) {
      if (!defaultAdsResponse[adType]) {
        // First, check if creator has specific default ads assigned
        const creatorDefaults = await db
          .select({
            id: ads.id,
            title: ads.title,
            description: ads.content,
            ad_type: ads.adType,
            placement: ads.placement,
          })
          .from(defaultAdRelationship)
          .innerJoin(ads, eq(defaultAdRelationship.adId, ads.id))
          .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
          .where(
            and(
              eq(defaultAdRelationship.creatorId, creatorId),
              eq(defaultAdRelationship.adType, adType),
              eq(defaultAdRelationship.isGlobalDefault, false),
              eq(ads.status, "active"),
              eq(adCampaigns.status, "active")
            )
          )
          .limit(1);

        if (creatorDefaults.length > 0) {
          const primaryAd = creatorDefaults[0];
          defaultAdsResponse[adType] = {
            ad_type: adType,
            placement: primaryAd.placement,
            current_ad: {
              id: primaryAd.id,
              title: primaryAd.title,
              description: primaryAd.description,
              ad_type: adType,
              image_url: null,
            },
            alternatives: [],
            source: "creator_default",
          };
        } else {
          // Fallback to any ads of this type if no creator-specific defaults
          const fallbackAds = await db
            .select({
              id: ads.id,
              title: ads.title,
              description: ads.content,
              ad_type: ads.adType,
              placement: ads.placement,
            })
            .from(ads)
            .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
            .where(
              and(
                eq(ads.status, "active"),
                eq(adCampaigns.status, "active"),
                eq(ads.adType, adType)
              )
            )
            .limit(6);

          if (fallbackAds.length > 0) {
            const primaryAd = fallbackAds[0];
            defaultAdsResponse[adType] = {
              ad_type: adType,
              placement: primaryAd.placement,
              current_ad: {
                id: primaryAd.id,
                title: primaryAd.title,
                description: primaryAd.description,
                ad_type: adType,
                image_url: null,
              },
              alternatives: fallbackAds.slice(1, 6).map(ad => ({
                id: ad.id,
                title: ad.title,
                description: ad.description,
                ad_type: adType,
                image_url: null,
              })),
              source: "fallback",
            };
          } else {
            // Create empty assignment if no ads available
            defaultAdsResponse[adType] = {
              ad_type: adType,
              placement: "default",
              current_ad: null,
              alternatives: [],
              source: "fallback",
            };
          }
        }
      }
    }

    console.log('✅ [Default Ads] Returning assignments:', {
      creatorId,
      conversationId: conversationId || 'none',
      adTypes: Object.keys(defaultAdsResponse),
      totalAds: Object.values(defaultAdsResponse).filter(ad => ad.current_ad).length
    });

    return NextResponse.json(defaultAdsResponse);

  } catch (error) {
    console.error("Error fetching default ads:", error);
    return NextResponse.json(
      { error: "Failed to fetch default ads" },
      { status: 500 }
    );
  }
}

export async function PUT(request: NextRequest) {
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
    const validatedData = defaultAdUpdateRequestSchema.parse(body);

    // Validate that all ad IDs exist
    const adIds = validatedData.assignments.map(a => a.ad_id);
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
          sql`${ads.id} = ANY(${sql.raw(`'{${adIds.join(',')}}'::uuid[]`)})`,
          eq(ads.status, "active"),
          eq(adCampaigns.status, "active")
        )
      );

    if (validAds.length !== adIds.length) {
      return NextResponse.json(
        { error: "Some ad IDs are invalid or inaccessible" },
        { status: 400 }
      );
    }

    // Update the default_ad_relationship table with new assignments
    await db.transaction(async (tx) => {
      // First, delete all existing creator-specific assignments
      await tx
        .delete(defaultAdRelationship)
        .where(
          and(
            eq(defaultAdRelationship.creatorId, creatorId),
            eq(defaultAdRelationship.isGlobalDefault, false)
          )
        );

      // Then insert new assignments
      for (const assignment of validatedData.assignments) {
        const { ad_type, placement, ad_id } = assignment;

        await tx
          .insert(defaultAdRelationship)
          .values({
            creatorId: creatorId,
            adId: ad_id,
            adType: ad_type,
            placement: placement,
            isGlobalDefault: false,
          });
      }
    });

    // Return the updated assignments with full ad details
    const updatedAssignments = validatedData.assignments.map(assignment => {
      const ad = validAds.find(a => a.id === assignment.ad_id);
      return {
        ad_type: assignment.ad_type,
        placement: assignment.placement,
        current_ad: ad ? {
          id: ad.id,
          title: ad.title,
          description: ad.description,
          ad_type: ad.ad_type,
          image_url: null,
        } : null,
        alternatives: [],
      };
    });

    console.log('✅ [Default Ads] Updated assignments:', {
      creatorId,
      count: updatedAssignments.length,
      assignments: updatedAssignments.map(a => ({
        type: a.ad_type,
        placement: a.placement,
        hasAd: !!a.current_ad
      }))
    });

    return NextResponse.json(updatedAssignments);

  } catch (error) {
    console.error("Error updating default ads:", error);
    
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
      { error: "Failed to update default ads" },
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
      "Access-Control-Allow-Methods": "GET, PUT, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    },
  });
}