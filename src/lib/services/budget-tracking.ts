import { db } from "@/lib/db/connection";
import { adCampaigns, adImpressions, adClicks, ads } from "@/lib/db/schema";
import { sql, eq, and, sum, desc } from "drizzle-orm";

export interface BudgetStatus {
  campaignId: string;
  budgetAmount: number;
  spentAmount: number;
  remainingBudget: number;
  isOutOfBudget: boolean;
  utilizationPercent: number;
  projectedDailySpend: number;
  daysRemaining: number;
}

export interface CampaignPerformance {
  campaignId: string;
  name: string;
  impressions: number;
  clicks: number;
  revenue: number;
  ctr: number;
  avgCpc: number;
  roi: number;
}

export class BudgetTrackingService {
  private static instance: BudgetTrackingService;

  static getInstance(): BudgetTrackingService {
    if (!this.instance) {
      this.instance = new BudgetTrackingService();
    }
    return this.instance;
  }

  /**
   * Get budget status for a campaign
   */
  async getCampaignBudgetStatus(campaignId: string): Promise<BudgetStatus | null> {
    try {
      const campaign = await db
        .select({
          id: adCampaigns.id,
          budgetAmount: adCampaigns.budgetAmount,
          spentAmount: adCampaigns.spentAmount,
          startDate: adCampaigns.startDate,
          endDate: adCampaigns.endDate,
        })
        .from(adCampaigns)
        .where(eq(adCampaigns.id, campaignId))
        .limit(1);

      if (campaign.length === 0) {
        return null;
      }

      const campaignData = campaign[0];
      const budgetAmount = parseFloat(campaignData.budgetAmount);
      const spentAmount = parseFloat(campaignData.spentAmount);
      const remainingBudget = budgetAmount - spentAmount;
      const isOutOfBudget = spentAmount >= budgetAmount;
      const utilizationPercent = budgetAmount > 0 ? (spentAmount / budgetAmount) * 100 : 0;

      // Calculate projected daily spend and days remaining
      const startDate = new Date(campaignData.startDate);
      const endDate = new Date(campaignData.endDate);
      const now = new Date();
      const totalDays = Math.ceil((endDate.getTime() - startDate.getTime()) / (1000 * 60 * 60 * 24));
      const elapsedDays = Math.ceil((now.getTime() - startDate.getTime()) / (1000 * 60 * 60 * 24));
      const daysRemaining = Math.max(0, totalDays - elapsedDays);
      const projectedDailySpend = elapsedDays > 0 ? spentAmount / elapsedDays : 0;

      return {
        campaignId,
        budgetAmount,
        spentAmount,
        remainingBudget,
        isOutOfBudget,
        utilizationPercent,
        projectedDailySpend,
        daysRemaining,
      };
    } catch (error) {
      console.error("Error getting campaign budget status:", error);
      throw new Error(`Failed to get budget status: ${error}`);
    }
  }

  /**
   * Update campaign spent amount (called when processing impressions/clicks)
   */
  async updateCampaignSpending(campaignId: string, amount: number): Promise<void> {
    try {
      await db
        .update(adCampaigns)
        .set({
          spentAmount: sql`${adCampaigns.spentAmount} + ${amount}`,
          updatedAt: new Date(),
        })
        .where(eq(adCampaigns.id, campaignId));

      // Check if campaign is now over budget
      const budgetStatus = await this.getCampaignBudgetStatus(campaignId);
      if (budgetStatus?.isOutOfBudget) {
        await this.pauseOverBudgetCampaign(campaignId);
      }
    } catch (error) {
      console.error("Error updating campaign spending:", error);
      throw new Error(`Failed to update spending: ${error}`);
    }
  }

  /**
   * Pause campaign when over budget
   */
  async pauseOverBudgetCampaign(campaignId: string): Promise<void> {
    try {
      // Pause the campaign
      await db
        .update(adCampaigns)
        .set({
          status: "paused",
          updatedAt: new Date(),
        })
        .where(eq(adCampaigns.id, campaignId));

      // Pause all ads in the campaign
      await db
        .update(ads)
        .set({
          status: "paused",
          updatedAt: new Date(),
        })
        .where(eq(ads.campaignId, campaignId));

      console.log(`Campaign ${campaignId} paused due to budget exhaustion`);
    } catch (error) {
      console.error("Error pausing over-budget campaign:", error);
      throw new Error(`Failed to pause campaign: ${error}`);
    }
  }

  /**
   * Get campaign performance metrics
   */
  async getCampaignPerformance(
    campaignId: string,
    timeframe: "24h" | "7d" | "30d" = "7d"
  ): Promise<CampaignPerformance> {
    try {
      const intervalMap = {
        "24h": "1 day",
        "7d": "7 days",
        "30d": "30 days"
      };

      // Get campaign name
      const campaignInfo = await db
        .select({
          name: adCampaigns.name,
        })
        .from(adCampaigns)
        .where(eq(adCampaigns.id, campaignId))
        .limit(1);

      const campaignName = campaignInfo[0]?.name || "Unknown Campaign";

      // Get performance metrics
      const performance = await db
        .select({
          impressions: sql<number>`COUNT(DISTINCT ${adImpressions.id})`,
          clicks: sql<number>`COUNT(DISTINCT ${adClicks.id})`,
          revenue: sql<number>`COALESCE(SUM(CAST(${adImpressions.revenueAmount} AS DECIMAL)), 0)`,
        })
        .from(adImpressions)
        .leftJoin(adClicks, eq(adClicks.impressionId, adImpressions.id))
        .leftJoin(ads, eq(ads.id, adImpressions.adId))
        .where(
          and(
            eq(ads.campaignId, campaignId),
            sql`${adImpressions.createdAt} > NOW() - INTERVAL ${intervalMap[timeframe]}`
          )
        );

      const result = performance[0];
      const impressions = result?.impressions || 0;
      const clicks = result?.clicks || 0;
      const revenue = result?.revenue || 0;
      const ctr = impressions > 0 ? (clicks / impressions) * 100 : 0;
      const avgCpc = clicks > 0 ? revenue / clicks : 0;
      
      // ROI calculation (simplified)
      const budgetStatus = await this.getCampaignBudgetStatus(campaignId);
      const spent = budgetStatus?.spentAmount || 0;
      const roi = spent > 0 ? ((revenue - spent) / spent) * 100 : 0;

      return {
        campaignId,
        name: campaignName,
        impressions,
        clicks,
        revenue,
        ctr,
        avgCpc,
        roi,
      };
    } catch (error) {
      console.error("Error getting campaign performance:", error);
      return {
        campaignId,
        name: "Error",
        impressions: 0,
        clicks: 0,
        revenue: 0,
        ctr: 0,
        avgCpc: 0,
        roi: 0,
      };
    }
  }

  /**
   * Get all campaigns with budget issues
   */
  async getCampaignsWithBudgetIssues(): Promise<BudgetStatus[]> {
    try {
      const campaigns = await db
        .select()
        .from(adCampaigns)
        .where(eq(adCampaigns.status, "active"));

      const budgetStatuses = await Promise.all(
        campaigns.map(campaign => this.getCampaignBudgetStatus(campaign.id))
      );

      return budgetStatuses
        .filter((status): status is BudgetStatus => status !== null)
        .filter(status => 
          status.isOutOfBudget || 
          status.utilizationPercent > 90 ||
          (status.daysRemaining > 0 && status.projectedDailySpend * status.daysRemaining > status.remainingBudget)
        );
    } catch (error) {
      console.error("Error getting campaigns with budget issues:", error);
      return [];
    }
  }

  /**
   * Process impression billing (update campaign spend)
   */
  async processImpressionBilling(impressionId: string): Promise<void> {
    try {
      // Get impression details
      const impression = await db
        .select({
          adId: adImpressions.adId,
          revenueAmount: adImpressions.revenueAmount,
          status: adImpressions.status,
        })
        .from(adImpressions)
        .where(eq(adImpressions.id, impressionId))
        .limit(1);

      if (impression.length === 0 || impression[0].status === "billed") {
        return; // Already billed or not found
      }

      // Get ad's campaign
      const ad = await db
        .select({ campaignId: ads.campaignId })
        .from(ads)
        .where(eq(ads.id, impression[0].adId))
        .limit(1);

      if (ad.length === 0) {
        throw new Error("Ad not found for impression");
      }

      const campaignId = ad[0].campaignId;
      const revenueAmount = parseFloat(impression[0].revenueAmount);

      // Update campaign spending
      await this.updateCampaignSpending(campaignId, revenueAmount);

      // Mark impression as billed
      await db
        .update(adImpressions)
        .set({
          status: "billed",
          updatedAt: new Date(),
        })
        .where(eq(adImpressions.id, impressionId));

    } catch (error) {
      console.error("Error processing impression billing:", error);
      throw new Error(`Failed to process billing: ${error}`);
    }
  }

  /**
   * Process click billing (for CPC campaigns)
   */
  async processClickBilling(clickId: string): Promise<void> {
    try {
      // Get click details
      const clickData = await db
        .select({
          impressionId: adClicks.impressionId,
          isBilled: adClicks.isBilled,
        })
        .from(adClicks)
        .where(eq(adClicks.id, clickId))
        .limit(1);

      if (clickData.length === 0 || clickData[0].isBilled) {
        return; // Already billed or not found
      }

      // Process the associated impression billing
      await this.processImpressionBilling(clickData[0].impressionId);

      // Mark click as billed
      await db
        .update(adClicks)
        .set({
          isBilled: true,
        })
        .where(eq(adClicks.id, clickId));

    } catch (error) {
      console.error("Error processing click billing:", error);
      throw new Error(`Failed to process click billing: ${error}`);
    }
  }

  /**
   * Get budget utilization report for all active campaigns
   */
  async getBudgetUtilizationReport(): Promise<{
    totalBudget: number;
    totalSpent: number;
    totalRemaining: number;
    campaignCount: number;
    overBudgetCount: number;
    campaigns: BudgetStatus[];
  }> {
    try {
      const activeCampaigns = await db
        .select()
        .from(adCampaigns)
        .where(eq(adCampaigns.status, "active"));

      const budgetStatuses = await Promise.all(
        activeCampaigns.map(campaign => this.getCampaignBudgetStatus(campaign.id))
      );

      const validStatuses = budgetStatuses.filter((status): status is BudgetStatus => status !== null);

      const totalBudget = validStatuses.reduce((acc, status) => acc + status.budgetAmount, 0);
      const totalSpent = validStatuses.reduce((acc, status) => acc + status.spentAmount, 0);
      const totalRemaining = validStatuses.reduce((acc, status) => acc + status.remainingBudget, 0);
      const overBudgetCount = validStatuses.filter(status => status.isOutOfBudget).length;

      return {
        totalBudget,
        totalSpent,
        totalRemaining,
        campaignCount: validStatuses.length,
        overBudgetCount,
        campaigns: validStatuses,
      };
    } catch (error) {
      console.error("Error generating budget utilization report:", error);
      throw new Error(`Failed to generate report: ${error}`);
    }
  }
}

// Export singleton instance
export const budgetTrackingService = BudgetTrackingService.getInstance();