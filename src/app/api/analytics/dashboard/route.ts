import { NextRequest, NextResponse } from "next/server";
import { budgetTrackingService } from "@/lib/services/budget-tracking";
import { adServingService } from "@/lib/services/ad-serving";
import { db } from "@/lib/db/connection";
import { adImpressions, adClicks, chatSessions, creators } from "@/lib/db/schema";
import { sql, eq, and, desc } from "drizzle-orm";
import { z } from "zod";

const dashboardQuerySchema = z.object({
  creator_id: z.string().uuid().optional(),
  timeframe: z.enum(["24h", "7d", "30d"]).default("7d"),
  include_campaigns: z.boolean().default(true),
  include_performance: z.boolean().default(true),
});

export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const params = {
      creator_id: searchParams.get('creator_id') || undefined,
      timeframe: (searchParams.get('timeframe') as "24h" | "7d" | "30d") || "7d",
      include_campaigns: searchParams.get('include_campaigns') !== 'false',
      include_performance: searchParams.get('include_performance') !== 'false',
    };

    const validatedParams = dashboardQuerySchema.parse(params);

    // Get time interval for queries
    const intervalMap = {
      "24h": "1 day",
      "7d": "7 days", 
      "30d": "30 days"
    };
    const interval = intervalMap[validatedParams.timeframe];

    // Base dashboard metrics
    const dashboardData: any = {
      timeframe: validatedParams.timeframe,
      generated_at: new Date().toISOString(),
    };

    // Overall statistics
    const overallStats = await getOverallStats(validatedParams.creator_id, interval);
    dashboardData.overall_stats = overallStats;

    // Campaign performance if requested
    if (validatedParams.include_campaigns) {
      const campaignPerformance = await getCampaignPerformance(validatedParams.creator_id, validatedParams.timeframe);
      dashboardData.campaign_performance = campaignPerformance;
    }

    // Detailed performance metrics if requested
    if (validatedParams.include_performance) {
      const performanceMetrics = await getDetailedPerformance(validatedParams.creator_id, interval);
      dashboardData.performance_metrics = performanceMetrics;
    }

    // Budget utilization report
    const budgetReport = await budgetTrackingService.getBudgetUtilizationReport();
    dashboardData.budget_report = {
      total_budget: budgetReport.totalBudget,
      total_spent: budgetReport.totalSpent,
      total_remaining: budgetReport.totalRemaining,
      utilization_percent: budgetReport.totalBudget > 0 
        ? (budgetReport.totalSpent / budgetReport.totalBudget) * 100 
        : 0,
      campaigns_count: budgetReport.campaignCount,
      over_budget_count: budgetReport.overBudgetCount,
    };

    // Recent activity
    const recentActivity = await getRecentActivity(validatedParams.creator_id);
    dashboardData.recent_activity = recentActivity;

    return NextResponse.json(dashboardData);

  } catch (error) {
    console.error("Error generating dashboard:", error);
    
    if (error instanceof z.ZodError) {
      return NextResponse.json(
        { 
          error: "Invalid query parameters", 
          details: error.errors 
        },
        { status: 400 }
      );
    }

    return NextResponse.json(
      { error: "Failed to generate dashboard" },
      { status: 500 }
    );
  }
}

async function getOverallStats(creatorId: string | undefined, interval: string) {
  const whereClause = creatorId 
    ? and(
        eq(adImpressions.creatorId, creatorId),
        sql`${adImpressions.createdAt} > NOW() - INTERVAL ${interval}`
      )
    : sql`${adImpressions.createdAt} > NOW() - INTERVAL ${interval}`;

  const stats = await db
    .select({
      totalImpressions: sql<number>`COUNT(*)`,
      totalClicks: sql<number>`COUNT(${adClicks.id})`,
      totalRevenue: sql<number>`COALESCE(SUM(CAST(${adImpressions.revenueAmount} AS DECIMAL)), 0)`,
      uniqueSessions: sql<number>`COUNT(DISTINCT ${adImpressions.sessionId})`,
    })
    .from(adImpressions)
    .leftJoin(adClicks, eq(adClicks.impressionId, adImpressions.id))
    .where(whereClause);

  const result = stats[0];
  const impressions = result?.totalImpressions || 0;
  const clicks = result?.totalClicks || 0;
  const revenue = result?.totalRevenue || 0;
  const sessions = result?.uniqueSessions || 0;

  return {
    total_impressions: impressions,
    total_clicks: clicks,
    total_revenue: revenue,
    unique_sessions: sessions,
    click_through_rate: impressions > 0 ? (clicks / impressions) * 100 : 0,
    avg_revenue_per_impression: impressions > 0 ? revenue / impressions : 0,
    avg_revenue_per_session: sessions > 0 ? revenue / sessions : 0,
  };
}

async function getCampaignPerformance(creatorId: string | undefined, timeframe: "24h" | "7d" | "30d") {
  // Get all active campaigns and their performance
  const campaignQuery = db
    .select({
      campaignId: sql<string>`c.id`,
      campaignName: sql<string>`c.name`,
      advertiserName: sql<string>`a.name`,
    })
    .from(sql`ad_campaigns c`)
    .leftJoin(sql`advertisers a`, sql`c.advertiser_id = a.id`)
    .where(sql`c.status = 'active'`);

  if (creatorId) {
    // Filter by creator if specified - this would need proper join logic
  }

  const campaigns = await campaignQuery.limit(10);

  const campaignPerformance = await Promise.all(
    campaigns.map(async (campaign) => {
      return await budgetTrackingService.getCampaignPerformance(
        campaign.campaignId,
        timeframe
      );
    })
  );

  return campaignPerformance;
}

async function getDetailedPerformance(creatorId: string | undefined, interval: string) {
  // Ad type performance
  const adTypeStats = await db
    .select({
      adType: sql<string>`a.ad_type`,
      impressions: sql<number>`COUNT(i.id)`,
      clicks: sql<number>`COUNT(c.id)`,
      revenue: sql<number>`COALESCE(SUM(CAST(i.revenue_amount AS DECIMAL)), 0)`,
    })
    .from(sql`adImpressions i`)
    .leftJoin(sql`ads a`, sql`i.ad_id = a.id`)
    .leftJoin(sql`ad_clicks c`, sql`c.impression_id = i.id`)
    .where(
      creatorId 
        ? and(
            sql`i.creator_id = ${creatorId}`,
            sql`i.created_at > NOW() - INTERVAL ${interval}`
          )
        : sql`i.created_at > NOW() - INTERVAL ${interval}`
    )
    .groupBy(sql`a.ad_type`);

  // Placement performance
  const placementStats = await db
    .select({
      placement: sql<string>`i.ad_queue_placement`,
      impressions: sql<number>`COUNT(i.id)`,
      clicks: sql<number>`COUNT(c.id)`,
      revenue: sql<number>`COALESCE(SUM(CAST(i.revenue_amount AS DECIMAL)), 0)`,
    })
    .from(adImpressions)
    .leftJoin(adClicks, eq(adClicks.impressionId, adImpressions.id))
    .where(
      creatorId 
        ? and(
            eq(adImpressions.creatorId, creatorId),
            sql`${adImpressions.createdAt} > NOW() - INTERVAL ${interval}`
          )
        : sql`${adImpressions.createdAt} > NOW() - INTERVAL ${interval}`
    )
    .groupBy(adImpressions.adQueuePlacement);

  return {
    by_ad_type: adTypeStats.map(stat => ({
      ad_type: stat.adType,
      impressions: stat.impressions,
      clicks: stat.clicks,
      revenue: stat.revenue,
      ctr: stat.impressions > 0 ? (stat.clicks / stat.impressions) * 100 : 0,
    })),
    by_placement: placementStats.map(stat => ({
      placement: stat.placement,
      impressions: stat.impressions,
      clicks: stat.clicks,
      revenue: stat.revenue,
      ctr: stat.impressions > 0 ? (stat.clicks / stat.impressions) * 100 : 0,
    })),
  };
}

async function getRecentActivity(creatorId: string | undefined) {
  const recentImpressions = await db
    .select({
      id: adImpressions.id,
      adId: adImpressions.adId,
      creatorId: adImpressions.creatorId,
      status: adImpressions.status,
      revenueAmount: adImpressions.revenueAmount,
      createdAt: adImpressions.createdAt,
      adTitle: sql<string>`a.title`,
      campaignName: sql<string>`c.name`,
    })
    .from(adImpressions)
    .leftJoin(sql`ads a`, sql`a.id = ${adImpressions.adId}`)
    .leftJoin(sql`ad_campaigns c`, sql`c.id = a.campaign_id`)
    .where(
      creatorId 
        ? eq(adImpressions.creatorId, creatorId)
        : sql`true`
    )
    .orderBy(desc(adImpressions.createdAt))
    .limit(20);

  return recentImpressions.map(impression => ({
    id: impression.id,
    type: "impression",
    ad_title: impression.adTitle,
    campaign_name: impression.campaignName,
    revenue: parseFloat(impression.revenueAmount),
    status: impression.status,
    created_at: impression.createdAt.toISOString(),
  }));
}