import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { businessSettings, creators } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";
import { withApiKey, checkResourceAccess, type ApiKeyValidation } from "@/lib/middleware/api-key";

// Business Settings Update Schema
const businessSettingsUpdateSchema = z.object({
  ad_frequency: z.enum(['low', 'normal', 'high']).optional(),
  revenue_vs_relevance: z.number().min(0.0).max(1.0).optional(),
  min_seconds_between_display_ads: z.number().min(5).max(300).optional(),
  display_ad_similarity_threshold: z.number().min(0.0).max(1.0).optional(),
});

async function handleGet(request: NextRequest, validation: ApiKeyValidation): Promise<NextResponse> {
  try {
    const { searchParams } = new URL(request.url);
    const creatorId = searchParams.get('creator_id');

    if (!creatorId) {
      return NextResponse.json(
        { error: "Creator ID is required" },
        { status: 400 }
      );
    }

    // Get creator's user ID to verify ownership
    const creatorResult = await db
      .select({ userId: creators.userId })
      .from(creators)
      .where(eq(creators.id, creatorId))
      .limit(1);

    if (creatorResult.length === 0) {
      return NextResponse.json(
        { error: "Creator not found" },
        { status: 404 }
      );
    }

    // Check if API key user can access this creator's settings
    if (!checkResourceAccess(validation, creatorResult[0].userId)) {
      return NextResponse.json(
        { error: "Access denied: You can only access your own creator settings" },
        { status: 403 }
      );
    }

    // Get current business settings
    const settings = await db
      .select()
      .from(businessSettings)
      .where(eq(businessSettings.creatorId, creatorId))
      .limit(1);

    if (settings.length === 0) {
      // Return default settings if none exist
      console.log(`No business settings found for creator ${creatorId}, returning defaults`);
      return NextResponse.json({
        ad_frequency: 'normal',
        revenue_vs_relevance: 0.5,
        min_seconds_between_display_ads: 30,
        display_ad_similarity_threshold: 0.25,
        is_active: true,
        last_modified_at: null,
      });
    }

    const setting = settings[0];
    return NextResponse.json({
      ad_frequency: setting.adFrequency,
      revenue_vs_relevance: parseFloat(setting.revenueVsRelevance || '0.5'),
      min_seconds_between_display_ads: parseInt(setting.minSecondsBetweenDisplayAds || '30'),
      display_ad_similarity_threshold: parseFloat(setting.displayAdSimilarityThreshold || '0.25'),
      is_active: setting.isActive,
      last_modified_at: setting.updatedAt?.toISOString(),
    });

  } catch (error) {
    console.error("Error fetching business settings:", error);
    return NextResponse.json(
      { error: "Failed to fetch settings" },
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
    const validatedData = businessSettingsUpdateSchema.parse(body);

    // Check if settings exist
    const existingSettings = await db
      .select()
      .from(businessSettings)
      .where(eq(businessSettings.creatorId, creatorId))
      .limit(1);

    const updateData = {
      adFrequency: validatedData.ad_frequency,
      revenueVsRelevance: validatedData.revenue_vs_relevance?.toString(),
      minSecondsBetweenDisplayAds: validatedData.min_seconds_between_display_ads?.toString(),
      displayAdSimilarityThreshold: validatedData.display_ad_similarity_threshold?.toString(),
      updatedAt: new Date(),
    };

    let updatedSettings;
    if (existingSettings.length === 0) {
      // Create new settings
      updatedSettings = await db
        .insert(businessSettings)
        .values({
          creatorId,
          adFrequency: updateData.adFrequency || 'normal',
          revenueVsRelevance: updateData.revenueVsRelevance || '0.5',
          minSecondsBetweenDisplayAds: updateData.minSecondsBetweenDisplayAds || '30',
          displayAdSimilarityThreshold: updateData.displayAdSimilarityThreshold || '0.25',
          isActive: true,
          createdAt: new Date(),
          updatedAt: new Date(),
        })
        .returning();
    } else {
      // Update existing settings
      updatedSettings = await db
        .update(businessSettings)
        .set(updateData)
        .where(eq(businessSettings.creatorId, creatorId))
        .returning();
    }

    const setting = updatedSettings[0];
    return NextResponse.json({
      ad_frequency: setting.adFrequency,
      revenue_vs_relevance: parseFloat(setting.revenueVsRelevance || '0.5'),
      min_seconds_between_display_ads: parseInt(setting.minSecondsBetweenDisplayAds || '30'),
      display_ad_similarity_threshold: parseFloat(setting.displayAdSimilarityThreshold || '0.25'),
      is_active: setting.isActive,
      last_modified_at: setting.updatedAt?.toISOString(),
    });

  } catch (error) {
    console.error("Error updating business settings:", error);
    
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
      { error: "Failed to update settings" },
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