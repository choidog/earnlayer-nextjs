import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { businessSettings, ads, adCampaigns } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";
import { z } from "zod";

// Ad Preview Request Schema
const adPreviewRequestSchema = z.object({
  queries: z.array(z.string()).optional(),
  settings_override: z.object({
    ad_frequency: z.enum(['low', 'normal', 'high']).optional(),
    revenue_vs_relevance: z.number().min(0.0).max(1.0).optional(),
    min_seconds_between_display_ads: z.number().min(5).max(300).optional(),
    display_ad_similarity_threshold: z.number().min(0.0).max(1.0).optional(),
  }).optional(),
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
    const validatedData = adPreviewRequestSchema.parse(body);

    // Get current business settings
    const settingsResult = await db
      .select()
      .from(businessSettings)
      .where(eq(businessSettings.creatorId, creatorId))
      .limit(1);

    // Default settings if none exist
    let currentSettings = {
      ad_frequency: 'normal' as const,
      revenue_vs_relevance: 0.5,
      min_seconds_between_display_ads: 30,
      display_ad_similarity_threshold: 0.25,
      settings_name: 'Default Settings',
      description: null,
      is_active: true,
      last_modified_at: null,
    };

    if (settingsResult.length > 0) {
      const setting = settingsResult[0];
      currentSettings = {
        ad_frequency: setting.adFrequency as 'low' | 'normal' | 'high',
        revenue_vs_relevance: parseFloat(setting.revenueVsRelevance || '0.5'),
        min_seconds_between_display_ads: setting.minSecondsBetweenDisplayAds || 30,
        display_ad_similarity_threshold: parseFloat(setting.displayAdSimilarityThreshold || '0.25'),
        settings_name: setting.settingsName || 'Default Settings',
        description: setting.description,
        is_active: setting.isActive ?? true,
        last_modified_at: setting.updatedAt?.toISOString() || null,
      };
    }

    // Apply any overrides
    const effectiveSettings = {
      ...currentSettings,
      ...(validatedData.settings_override || {})
    };

    // Get sample ads to use as fallbacks
    const fallbackAds = await db
      .select({
        id: ads.id,
        title: ads.title,
        description: ads.content,
        ad_type: ads.adType,
        placement: ads.placement,
        target_url: ads.targetUrl,
      })
      .from(ads)
      .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
      .where(
        and(
          eq(ads.status, "active"),
          eq(adCampaigns.status, "active")
        )
      )
      .limit(10);

    // Transform ads to expected format
    const adPreviews = fallbackAds.map(ad => ({
      id: ad.id,
      title: ad.title,
      description: ad.description,
      ad_type: ad.ad_type,
      image_url: null,
    }));

    // Mock contextual ads based on queries (in real implementation, this would use vector search)
    let contextualAds = [];
    if (validatedData.queries && validatedData.queries.length > 0) {
      // For demo purposes, return some ads that would theoretically match the queries
      contextualAds = adPreviews.slice(0, Math.min(3, validatedData.queries.length));
    }

    // Create similarity scores for the preview
    const similarityScores = {};
    if (validatedData.queries) {
      validatedData.queries.forEach((query, index) => {
        // Mock similarity score based on settings threshold
        const mockSimilarity = Math.max(
          effectiveSettings.display_ad_similarity_threshold + 0.1 + (index * 0.05),
          0.9
        );
        similarityScores[query] = Math.min(mockSimilarity, 1.0);
      });
    }

    const previewResponse = {
      contextual_ads: contextualAds,
      fallback_ads: adPreviews.slice(0, 5), // Limit fallback ads shown in preview
      timing_info: {
        min_seconds_between_ads: effectiveSettings.min_seconds_between_display_ads,
        ad_frequency: effectiveSettings.ad_frequency,
        similarity_threshold: effectiveSettings.display_ad_similarity_threshold,
        revenue_vs_relevance: effectiveSettings.revenue_vs_relevance,
      },
      similarity_scores: similarityScores,
      effective_settings: effectiveSettings,
      queries_processed: validatedData.queries?.length || 0,
    };

    console.log('✅ [Ad Preview] Generated preview:', {
      creatorId,
      queriesCount: validatedData.queries?.length || 0,
      contextualAdsCount: contextualAds.length,
      fallbackAdsCount: adPreviews.length,
      hasOverrides: !!validatedData.settings_override,
    });

    return NextResponse.json(previewResponse);

  } catch (error) {
    console.error("Error generating ad preview:", error);
    
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
      { error: "Failed to generate preview" },
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