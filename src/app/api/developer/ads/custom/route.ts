import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { ads, adCampaigns } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";

// Custom Ad Create Request Schema
const customAdCreateRequestSchema = z.object({
  title: z.string().min(1).max(255),
  description: z.string().min(1).max(1000),
  target_url: z.string().url(),
  ad_type: z.enum(['popup', 'banner', 'thinking', 'video', 'hyperlink']),
  placement: z.enum(['chat_inline', 'sidebar', 'content_promo', 'chat', 'default']).default('default'),
  campaign_id: z.string().uuid().optional(), // Optional - will create/use default campaign
});

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
    const validatedData = customAdCreateRequestSchema.parse(body);

    // Get or create a default campaign for this creator's custom ads
    let campaignId = validatedData.campaign_id;
    
    if (!campaignId) {
      // Look for existing "Custom Ads" campaign for this creator
      const existingCampaign = await db
        .select()
        .from(adCampaigns)
        .where(eq(adCampaigns.name, `Custom Ads - ${creatorId}`))
        .limit(1);

      if (existingCampaign.length > 0) {
        campaignId = existingCampaign[0].id;
      } else {
        // Create a new campaign for custom ads
        const newCampaign = await db
          .insert(adCampaigns)
          .values({
            advertiserId: creatorId, // Creator acts as advertiser for their custom ads
            name: `Custom Ads - ${creatorId}`,
            startDate: new Date(),
            endDate: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000), // 1 year from now
            budgetAmount: "1000.00", // Default budget
            spentAmount: "0.00",
            currency: "USD",
            status: "active",
            timeZone: "UTC",
            createdAt: new Date(),
            updatedAt: new Date(),
          })
          .returning();

        campaignId = newCampaign[0].id;
        console.log('✅ [Custom Ad] Created new campaign:', campaignId);
      }
    }

    // Create the custom ad
    const newAd = await db
      .insert(ads)
      .values({
        campaignId: campaignId,
        title: validatedData.title,
        content: validatedData.description,
        targetUrl: validatedData.target_url,
        adType: validatedData.ad_type,
        status: "active",
        placement: validatedData.placement,
        pricingModel: "cpc",
        bidAmount: "0.10", // Default bid
        currency: "USD",
        createdAt: new Date(),
        updatedAt: new Date(),
      })
      .returning();

    const createdAd = newAd[0];

    // Return the created ad in the expected format
    const adPreview = {
      id: createdAd.id,
      title: createdAd.title,
      description: createdAd.content,
      ad_type: createdAd.adType,
      image_url: null,
      target_url: createdAd.targetUrl,
      placement: createdAd.placement,
      status: createdAd.status,
      created_at: createdAd.createdAt?.toISOString(),
    };

    console.log('✅ [Custom Ad] Created custom ad:', {
      creatorId,
      adId: createdAd.id,
      title: createdAd.title,
      adType: createdAd.adType,
      campaignId
    });

    return NextResponse.json(adPreview, { status: 201 });

  } catch (error) {
    console.error("Error creating custom ad:", error);
    
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
      { error: "Failed to create custom ad" },
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