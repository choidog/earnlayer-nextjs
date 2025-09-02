import { NextRequest, NextResponse } from "next/server";

// Predefined settings templates
const SETTINGS_TEMPLATES = [
  {
    id: "conservative",
    name: "Conservative",
    description: "Lower ad frequency, higher relevance threshold for quality-focused content creators",
    settings: {
      ad_frequency: "low",
      revenue_vs_relevance: 0.3,
      min_seconds_between_display_ads: 60,
      display_ad_similarity_threshold: 0.4,
    }
  },
  {
    id: "balanced",
    name: "Balanced",
    description: "Default balanced settings for most creators",
    settings: {
      ad_frequency: "normal",
      revenue_vs_relevance: 0.5,
      min_seconds_between_display_ads: 30,
      display_ad_similarity_threshold: 0.25,
    }
  },
  {
    id: "aggressive",
    name: "Revenue Focused",
    description: "Higher ad frequency, lower relevance threshold for maximum revenue",
    settings: {
      ad_frequency: "high",
      revenue_vs_relevance: 0.7,
      min_seconds_between_display_ads: 15,
      display_ad_similarity_threshold: 0.1,
    }
  },
  {
    id: "content_first",
    name: "Content First",
    description: "Minimal ads, maximum relevance for content-focused creators",
    settings: {
      ad_frequency: "low",
      revenue_vs_relevance: 0.2,
      min_seconds_between_display_ads: 90,
      display_ad_similarity_threshold: 0.6,
    }
  }
];

export async function GET(request: NextRequest) {
  try {
    console.log('✅ [Settings Templates] Returning predefined templates');
    
    return NextResponse.json(SETTINGS_TEMPLATES);

  } catch (error) {
    console.error("Error fetching settings templates:", error);
    return NextResponse.json(
      { error: "Failed to fetch templates" },
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