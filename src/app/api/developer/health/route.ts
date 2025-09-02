import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { ads, adCampaigns, businessSettings } from "@/lib/db/schema";
import { eq, and, sql } from "drizzle-orm";

export async function GET(request: NextRequest) {
  try {
    // Perform health checks on developer-related functionality
    const healthChecks = {
      database_connection: false,
      active_ads_count: 0,
      active_campaigns_count: 0,
      business_settings_accessible: false,
      endpoints_status: "healthy",
      timestamp: new Date().toISOString(),
    };

    try {
      // Test database connection with a simple query
      const adCount = await db
        .select({ count: sql<number>`count(*)` })
        .from(ads)
        .innerJoin(adCampaigns, eq(ads.campaignId, adCampaigns.id))
        .where(
          and(
            eq(ads.status, "active"),
            eq(adCampaigns.status, "active")
          )
        );

      healthChecks.database_connection = true;
      healthChecks.active_ads_count = adCount[0]?.count || 0;

      // Get active campaigns count
      const campaignCount = await db
        .select({ count: sql<number>`count(*)` })
        .from(adCampaigns)
        .where(eq(adCampaigns.status, "active"));

      healthChecks.active_campaigns_count = campaignCount[0]?.count || 0;

      // Test business settings table accessibility
      const settingsTest = await db
        .select({ count: sql<number>`count(*)` })
        .from(businessSettings)
        .limit(1);

      healthChecks.business_settings_accessible = true;

    } catch (dbError) {
      console.error("Database health check failed:", dbError);
      healthChecks.endpoints_status = "degraded";
    }

    // Determine overall health status
    let overallStatus = "healthy";
    if (!healthChecks.database_connection || !healthChecks.business_settings_accessible) {
      overallStatus = "unhealthy";
    } else if (healthChecks.active_ads_count === 0 || healthChecks.active_campaigns_count === 0) {
      overallStatus = "warning";
    }

    const healthResponse = {
      status: overallStatus,
      service: "developer-settings",
      checks: healthChecks,
      version: "1.0.0",
      uptime_seconds: process.uptime(),
      available_endpoints: [
        "GET /api/developer/health",
        "GET /api/developer/settings",
        "PUT /api/developer/settings", 
        "GET /api/developer/settings/templates",
        "GET /api/developer/ad-sets",
        "POST /api/developer/ad-sets",
        "GET /api/developer/ad-sets/{id}/ads",
        "GET /api/developer/default-ads",
        "PUT /api/developer/default-ads",
        "POST /api/developer/ads/custom",
        "POST /api/developer/preview",
        "POST /api/developer/admin/init-system-ad-sets",
      ],
      dependencies: {
        database: healthChecks.database_connection ? "healthy" : "unhealthy",
        ads_system: healthChecks.active_ads_count > 0 ? "healthy" : "warning",
        campaigns_system: healthChecks.active_campaigns_count > 0 ? "healthy" : "warning",
      },
    };

    console.log('✅ [Developer Health] Health check completed:', {
      status: overallStatus,
      activeAds: healthChecks.active_ads_count,
      activeCampaigns: healthChecks.active_campaigns_count,
      dbConnection: healthChecks.database_connection
    });

    // Return appropriate HTTP status based on health
    const httpStatus = overallStatus === "healthy" ? 200 : 
                      overallStatus === "warning" ? 200 : 503;

    return NextResponse.json(healthResponse, { status: httpStatus });

  } catch (error) {
    console.error("Error during developer health check:", error);
    
    return NextResponse.json({
      status: "unhealthy",
      service: "developer-settings",
      error: "Health check failed",
      timestamp: new Date().toISOString(),
      uptime_seconds: process.uptime(),
    }, { status: 503 });
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