import { db } from "@/lib/db/connection";
import { ads, adImpressions, adCampaigns, chatSessions, adClicks } from "@/lib/db/schema";
import { sql, eq, and, desc, isNull, ne } from "drizzle-orm";
import { vectorSearchService, type VectorSearchResult } from "./vector-search";
import { embeddingService } from "./embeddings";

export interface AdServingOptions {
  creatorId: string;
  sessionId?: string;
  adType?: "text" | "banner" | "video" | "hyperlink" | "popup" | "thinking";
  placement?: "chat_inline" | "sidebar" | "content_promo" | "chat" | "default";
  limit?: number;
  similarityThreshold?: number;
  contextualMessages?: number;
  excludeAdIds?: string[];
  revenueWeight?: number; // 0-1, weight for revenue optimization
}

export interface ServedAd {
  id: string;
  title: string;
  content: string;
  targetUrl: string | null;
  adType: string;
  placement: string;
  similarity: number;
  revenue: number;
  impressionId?: string;
  metadata?: Record<string, any>;
}

export interface AdServingResult {
  ads: ServedAd[];
  sessionId: string;
  placement: string;
  totalAvailable: number;
  averageSimilarity: number;
  reason: string;
}

export interface DisplayAdTimingResult {
  shouldShow: boolean;
  endpointUrl?: string;
  reason: string;
  adsAvailable: number;
  thresholdUsed: number;
}

export class AdServingService {
  private static instance: AdServingService;

  static getInstance(): AdServingService {
    if (!this.instance) {
      this.instance = new AdServingService();
    }
    return this.instance;
  }

  /**
   * Main ad serving method - contextual ads based on conversation
   */
  async serveContextualAds(
    query: string,
    options: AdServingOptions
  ): Promise<AdServingResult> {
    try {
      const {
        creatorId,
        sessionId,
        adType = "hyperlink",
        placement = "default",
        limit = 3,
        similarityThreshold = 0.25,
        excludeAdIds = [],
        revenueWeight = 0.3,
      } = options;

      // Get contextual ads using vector search
      const vectorResults = await vectorSearchService.hybridAdSearch(query, {
        limit: limit * 2, // Get more candidates for filtering
        vectorWeight: 1 - revenueWeight,
        revenueBoost: 1.2,
        filters: {
          adType,
          excludeAdIds,
        }
      });

      if (vectorResults.length === 0) {
        return {
          ads: [],
          sessionId: sessionId || "",
          placement,
          totalAvailable: 0,
          averageSimilarity: 0,
          reason: "No ads found matching criteria"
        };
      }

      // Filter by similarity threshold
      const qualifiedAds = vectorResults.filter(
        result => result.similarity >= similarityThreshold
      );

      if (qualifiedAds.length === 0) {
        return {
          ads: [],
          sessionId: sessionId || "",
          placement,
          totalAvailable: vectorResults.length,
          averageSimilarity: vectorResults.reduce((acc, r) => acc + r.similarity, 0) / vectorResults.length,
          reason: `No ads meet similarity threshold of ${similarityThreshold}`
        };
      }

      // Convert to served ads and create impressions
      const servedAds: ServedAd[] = [];
      
      for (let i = 0; i < Math.min(limit, qualifiedAds.length); i++) {
        const result = qualifiedAds[i];
        const revenue = this.calculateRevenue(result.ad.bidAmount?.toString() || "0");
        
        // Create impression record
        const impressionId = sessionId 
          ? await this.recordImpression(result.ad.id, creatorId, sessionId, placement, revenue)
          : undefined;

        servedAds.push({
          id: result.ad.id,
          title: result.ad.title,
          content: result.ad.content,
          targetUrl: result.ad.targetUrl,
          adType: result.ad.adType,
          placement: result.ad.placement,
          similarity: result.similarity,
          revenue,
          impressionId,
          metadata: {
            campaignId: result.ad.campaignId,
            pricingModel: result.ad.pricingModel,
          }
        });
      }

      const avgSimilarity = servedAds.reduce((acc, ad) => acc + ad.similarity, 0) / servedAds.length;

      return {
        ads: servedAds,
        sessionId: sessionId || "",
        placement,
        totalAvailable: qualifiedAds.length,
        averageSimilarity: avgSimilarity,
        reason: "Successfully served contextual ads"
      };

    } catch (error) {
      console.error("Error serving contextual ads:", error);
      throw new Error(`Failed to serve ads: ${error}`);
    }
  }

  /**
   * Serve ads based on conversation history
   */
  async serveConversationAds(
    sessionId: string,
    options: AdServingOptions
  ): Promise<AdServingResult> {
    try {
      // Get contextual ads based on recent conversation
      const vectorResults = await vectorSearchService.getContextualAds(sessionId, {
        limit: options.limit || 3,
        lookbackMessages: options.contextualMessages || 10,
        threshold: options.similarityThreshold || 0.25,
        filters: {
          adType: options.adType,
          placement: options.placement,
          excludeAdIds: options.excludeAdIds,
        }
      });

      if (vectorResults.length === 0) {
        // Fallback to default ads for creator
        return this.serveDefaultAds(options);
      }

      // Convert to served ads
      const servedAds: ServedAd[] = [];
      
      for (const result of vectorResults.slice(0, options.limit || 3)) {
        const revenue = this.calculateRevenue(result.ad.bidAmount?.toString() || "0");
        
        const impressionId = await this.recordImpression(
          result.ad.id, 
          options.creatorId, 
          sessionId, 
          options.placement || "default", 
          revenue
        );

        servedAds.push({
          id: result.ad.id,
          title: result.ad.title,
          content: result.ad.content,
          targetUrl: result.ad.targetUrl,
          adType: result.ad.adType,
          placement: result.ad.placement,
          similarity: result.similarity,
          revenue,
          impressionId,
        });
      }

      const avgSimilarity = servedAds.reduce((acc, ad) => acc + ad.similarity, 0) / servedAds.length;

      return {
        ads: servedAds,
        sessionId,
        placement: options.placement || "default",
        totalAvailable: vectorResults.length,
        averageSimilarity: avgSimilarity,
        reason: "Served ads based on conversation history"
      };

    } catch (error) {
      console.error("Error serving conversation ads:", error);
      throw new Error(`Failed to serve conversation ads: ${error}`);
    }
  }

  /**
   * Serve default/fallback ads for a creator
   */
  async serveDefaultAds(options: AdServingOptions): Promise<AdServingResult> {
    try {
      // Query for default ads or high-performing ads
      const defaultAds = await db
        .select()
        .from(ads)
        .where(
          and(
            eq(ads.status, "active"),
            isNull(ads.deletedAt),
            options.adType ? eq(ads.adType, options.adType) : sql`true`,
            options.placement ? eq(ads.placement, options.placement) : sql`true`
          )
        )
        .orderBy(desc(ads.bidAmount))
        .limit(options.limit || 3);

      const servedAds: ServedAd[] = [];
      
      for (const ad of defaultAds) {
        const revenue = this.calculateRevenue(ad.bidAmount?.toString() || "0");
        
        const impressionId = options.sessionId 
          ? await this.recordImpression(
              ad.id, 
              options.creatorId, 
              options.sessionId, 
              options.placement || "default", 
              revenue
            )
          : undefined;

        servedAds.push({
          id: ad.id,
          title: ad.title,
          content: ad.content,
          targetUrl: ad.targetUrl,
          adType: ad.adType,
          placement: ad.placement,
          similarity: 0.5, // Default similarity for fallback ads
          revenue,
          impressionId,
        });
      }

      return {
        ads: servedAds,
        sessionId: options.sessionId || "",
        placement: options.placement || "default",
        totalAvailable: defaultAds.length,
        averageSimilarity: 0.5,
        reason: "Served default/fallback ads"
      };

    } catch (error) {
      console.error("Error serving default ads:", error);
      throw new Error(`Failed to serve default ads: ${error}`);
    }
  }

  /**
   * Display ad timing logic - determines when to show display ads
   */
  async getDisplayAdTiming(
    sessionId: string,
    similarityThreshold: number = 0.25
  ): Promise<DisplayAdTimingResult> {
    try {
      // Check recent ad impressions for this session
      const recentImpressions = await db
        .select()
        .from(adImpressions)
        .where(
          and(
            eq(adImpressions.sessionId, sessionId),
            sql`${adImpressions.createdAt} > NOW() - INTERVAL '5 minutes'`
          )
        )
        .limit(5);

      // Basic timing logic - don't show if too many recent impressions
      if (recentImpressions.length >= 3) {
        return {
          shouldShow: false,
          reason: "Too many recent ad impressions",
          adsAvailable: 0,
          thresholdUsed: similarityThreshold
        };
      }

      // Check available ads for this session
      const availableAdsCount = await db
        .select({ count: sql<number>`count(*)` })
        .from(ads)
        .where(
          and(
            eq(ads.status, "active"),
            isNull(ads.deletedAt),
            eq(ads.adType, "banner") // Display ads are typically banners
          )
        );

      const adsAvailable = availableAdsCount[0]?.count || 0;

      if (adsAvailable === 0) {
        return {
          shouldShow: false,
          reason: "No display ads available",
          adsAvailable: 0,
          thresholdUsed: similarityThreshold
        };
      }

      // Show display ad
      return {
        shouldShow: true,
        endpointUrl: `/api/displayad/${sessionId}`,
        reason: "Display ad timing criteria met",
        adsAvailable,
        thresholdUsed: similarityThreshold
      };

    } catch (error) {
      console.error("Error checking display ad timing:", error);
      return {
        shouldShow: false,
        reason: "Error checking ad timing",
        adsAvailable: 0,
        thresholdUsed: similarityThreshold
      };
    }
  }

  /**
   * Record ad impression in database
   */
  private async recordImpression(
    adId: string,
    creatorId: string,
    sessionId: string,
    placement: string,
    revenue: number
  ): Promise<string> {
    try {
      const impression = await db
        .insert(adImpressions)
        .values({
          adId,
          creatorId,
          sessionId,
          status: "pending",
          revenueAmount: revenue.toString(),
          creatorPayoutAmount: (revenue * 0.7).toString(), // 70% creator payout
          currency: "USD",
          impressionType: "contextual",
          adQueuePlacement: placement,
        })
        .returning({ id: adImpressions.id });

      return impression[0].id;
    } catch (error) {
      console.error("Error recording impression:", error);
      throw new Error(`Failed to record impression: ${error}`);
    }
  }

  /**
   * Record ad click and update impression
   */
  async recordClick(
    impressionId: string,
    clickMetadata?: Record<string, any>
  ): Promise<string> {
    try {
      const click = await db
        .insert(adClicks)
        .values({
          impressionId,
          clickMetadata,
          isBilled: false,
        })
        .returning({ id: adClicks.id });

      // Update impression status
      await db
        .update(adImpressions)
        .set({ 
          status: "clicked",
          updatedAt: new Date(),
        })
        .where(eq(adImpressions.id, impressionId));

      return click[0].id;
    } catch (error) {
      console.error("Error recording click:", error);
      throw new Error(`Failed to record click: ${error}`);
    }
  }

  /**
   * Calculate revenue for an ad based on bid amount and pricing model
   */
  private calculateRevenue(bidAmount: string): number {
    const bid = parseFloat(bidAmount) || 0;
    // Simple CPC model - could be enhanced with CPM, etc.
    return bid;
  }

  /**
   * Get ad performance analytics
   */
  async getAdPerformance(
    adId: string,
    timeframe: "24h" | "7d" | "30d" = "7d"
  ): Promise<{
    impressions: number;
    clicks: number;
    revenue: number;
    ctr: number;
    avgSimilarity: number;
  }> {
    try {
      const intervalMap = {
        "24h": "1 day",
        "7d": "7 days", 
        "30d": "30 days"
      };

      const stats = await db
        .select({
          impressions: sql<number>`COUNT(*)`,
          clicks: sql<number>`COUNT(ac.id)`,
          revenue: sql<number>`COALESCE(SUM(CAST(${adImpressions.revenueAmount} AS DECIMAL)), 0)`,
          avgSimilarity: sql<number>`AVG(0.75)`, // Placeholder - would need to store similarity scores
        })
        .from(adImpressions)
        .leftJoin(adClicks, eq(adClicks.impressionId, adImpressions.id))
        .where(
          and(
            eq(adImpressions.adId, adId),
            sql`${adImpressions.createdAt} > NOW() - INTERVAL ${intervalMap[timeframe]}`
          )
        );

      const result = stats[0];
      const impressions = result?.impressions || 0;
      const clicks = result?.clicks || 0;
      const revenue = result?.revenue || 0;
      const ctr = impressions > 0 ? (clicks / impressions) * 100 : 0;
      const avgSimilarity = result?.avgSimilarity || 0;

      return {
        impressions,
        clicks,
        revenue,
        ctr,
        avgSimilarity,
      };
    } catch (error) {
      console.error("Error getting ad performance:", error);
      return {
        impressions: 0,
        clicks: 0,
        revenue: 0,
        ctr: 0,
        avgSimilarity: 0,
      };
    }
  }
}

// Export singleton instance
export const adServingService = AdServingService.getInstance();