import { db } from "@/lib/db/connection";
import { ads, chatMessages, type Ad } from "@/lib/db/schema";
import { sql, desc, and, eq, isNull } from "drizzle-orm";
import { embeddingService } from "./embeddings";

export interface VectorSearchResult {
  ad: Ad;
  similarity: number;
  distance: number;
}

export interface SearchFilters {
  campaignId?: string;
  adType?: string;
  placement?: string;
  status?: string;
  minBudget?: number;
  excludeAdIds?: string[];
}

export class VectorSearchService {
  private static instance: VectorSearchService;

  static getInstance(): VectorSearchService {
    if (!this.instance) {
      this.instance = new VectorSearchService();
    }
    return this.instance;
  }

  /**
   * Search for ads similar to a query text
   */
  async searchAds(
    query: string,
    options: {
      limit?: number;
      threshold?: number;
      filters?: SearchFilters;
    } = {}
  ): Promise<VectorSearchResult[]> {
    const { limit = 10, threshold = 0.7, filters = {} } = options;

    try {
      // Generate embedding for query
      const queryEmbedding = await embeddingService.generateEmbedding(query);
      
      return this.searchAdsByEmbedding(queryEmbedding, { limit, threshold, filters });
    } catch (error) {
      console.error("Error searching ads:", error);
      throw new Error(`Failed to search ads: ${error}`);
    }
  }

  /**
   * Search for ads using pre-computed embedding
   */
  async searchAdsByEmbedding(
    queryEmbedding: number[],
    options: {
      limit?: number;
      threshold?: number;
      filters?: SearchFilters;
    } = {}
  ): Promise<VectorSearchResult[]> {
    const { limit = 10, threshold = 0.7, filters = {} } = options;

    try {
      // Build WHERE conditions
      const whereConditions = [
        eq(ads.status, "active"),
        isNull(ads.deletedAt),
      ];

      if (filters.campaignId) {
        whereConditions.push(eq(ads.campaignId, filters.campaignId));
      }

      if (filters.adType) {
        whereConditions.push(eq(ads.adType, filters.adType as any));
      }

      if (filters.placement) {
        whereConditions.push(eq(ads.placement, filters.placement as any));
      }

      if (filters.excludeAdIds && filters.excludeAdIds.length > 0) {
        whereConditions.push(sql`${ads.id} NOT IN ${filters.excludeAdIds}`);
      }

      // Convert embedding to pgvector format
      const embeddingVector = `[${queryEmbedding.join(",")}]`;

      // Execute vector similarity search
      const results = await db
        .select({
          ad: ads,
          similarity: sql<number>`1 - (${ads.embedding} <-> ${embeddingVector}::vector)`.as("similarity"),
          distance: sql<number>`${ads.embedding} <-> ${embeddingVector}::vector`.as("distance"),
        })
        .from(ads)
        .where(and(...whereConditions))
        .orderBy(sql`${ads.embedding} <-> ${embeddingVector}::vector`)
        .limit(limit);

      // Filter by similarity threshold
      const filteredResults = results
        .filter(result => result.similarity >= threshold)
        .map(result => ({
          ad: result.ad,
          similarity: result.similarity,
          distance: result.distance,
        }));

      return filteredResults;
    } catch (error) {
      console.error("Error searching ads by embedding:", error);
      throw new Error(`Failed to search ads by embedding: ${error}`);
    }
  }

  /**
   * Search for similar messages (for context understanding)
   */
  async searchSimilarMessages(
    sessionId: string,
    queryText: string,
    limit: number = 5
  ): Promise<Array<{ message: any; similarity: number }>> {
    try {
      const queryEmbedding = await embeddingService.generateEmbedding(queryText);
      const embeddingVector = `[${queryEmbedding.join(",")}]`;

      const results = await db
        .select({
          message: chatMessages,
          similarity: sql<number>`1 - (${chatMessages.embedding} <-> ${embeddingVector}::vector)`.as("similarity"),
        })
        .from(chatMessages)
        .where(eq(chatMessages.sessionId, sessionId))
        .orderBy(sql`${chatMessages.embedding} <-> ${embeddingVector}::vector`)
        .limit(limit);

      return results;
    } catch (error) {
      console.error("Error searching similar messages:", error);
      throw new Error(`Failed to search similar messages: ${error}`);
    }
  }

  /**
   * Get contextual ads based on conversation history
   */
  async getContextualAds(
    sessionId: string,
    options: {
      limit?: number;
      lookbackMessages?: number;
      threshold?: number;
      filters?: SearchFilters;
    } = {}
  ): Promise<VectorSearchResult[]> {
    const { 
      limit = 5, 
      lookbackMessages = 10, 
      threshold = 0.7, 
      filters = {} 
    } = options;

    try {
      // Get recent messages from session
      const recentMessages = await db
        .select()
        .from(chatMessages)
        .where(eq(chatMessages.sessionId, sessionId))
        .orderBy(desc(chatMessages.createdAt))
        .limit(lookbackMessages);

      if (recentMessages.length === 0) {
        return [];
      }

      // Combine recent messages to create context
      const context = recentMessages
        .map(msg => msg.content)
        .reverse() // Chronological order
        .join("\n");

      // Search for ads based on conversation context
      return this.searchAds(context, { limit, threshold, filters });
    } catch (error) {
      console.error("Error getting contextual ads:", error);
      throw new Error(`Failed to get contextual ads: ${error}`);
    }
  }

  /**
   * Hybrid search combining vector similarity and business logic
   */
  async hybridAdSearch(
    query: string,
    options: {
      limit?: number;
      vectorWeight?: number; // 0-1, weight of vector similarity vs business score
      revenueBoost?: number; // Boost factor for higher revenue ads
      filters?: SearchFilters;
    } = {}
  ): Promise<VectorSearchResult[]> {
    const { 
      limit = 10, 
      vectorWeight = 0.7, 
      revenueBoost = 1.2,
      filters = {} 
    } = options;

    try {
      // Get vector similarity results
      const vectorResults = await this.searchAds(query, { 
        limit: limit * 2, // Get more candidates for re-ranking
        threshold: 0.5, // Lower threshold for hybrid search
        filters 
      });

      // Apply business logic scoring
      const scoredResults = vectorResults.map(result => {
        const vectorScore = result.similarity * vectorWeight;
        
        // Business score factors
        const bidAmount = parseFloat(result.ad.bidAmount?.toString() || "0");
        const revenueScore = Math.min(bidAmount / 10, 1) * revenueBoost; // Normalize and boost
        const businessScore = revenueScore * (1 - vectorWeight);
        
        const finalScore = vectorScore + businessScore;
        
        return {
          ...result,
          similarity: finalScore, // Update similarity with hybrid score
        };
      });

      // Sort by hybrid score and limit results
      return scoredResults
        .sort((a, b) => b.similarity - a.similarity)
        .slice(0, limit);
    } catch (error) {
      console.error("Error in hybrid ad search:", error);
      throw new Error(`Failed to perform hybrid ad search: ${error}`);
    }
  }

  /**
   * Batch update embeddings for existing ads
   */
  async updateAdEmbeddings(adIds?: string[]): Promise<void> {
    try {
      console.log("🔄 Updating ad embeddings...");
      
      // Query ads that need embedding updates
      const query = db.select().from(ads);
      const adsToUpdate = adIds 
        ? await query.where(sql`${ads.id} = ANY(${adIds})`)
        : await query.where(isNull(ads.embedding));

      console.log(`📊 Found ${adsToUpdate.length} ads to update`);

      // Process in batches to avoid rate limits
      for (let i = 0; i < adsToUpdate.length; i += 10) {
        const batch = adsToUpdate.slice(i, i + 10);
        
        await Promise.all(batch.map(async (ad) => {
          try {
            const embedding = await embeddingService.generateAdEmbedding(
              ad.title, 
              ad.content
            );
            
            await db
              .update(ads)
              .set({ 
                embedding: `[${embedding.join(",")}]` as any,
                updatedAt: new Date()
              })
              .where(eq(ads.id, ad.id));
              
            console.log(`✅ Updated embedding for ad: ${ad.title}`);
          } catch (error) {
            console.error(`❌ Failed to update embedding for ad ${ad.id}:`, error);
          }
        }));

        // Rate limiting delay
        if (i + 10 < adsToUpdate.length) {
          await new Promise(resolve => setTimeout(resolve, 1000));
        }
      }

      console.log("✅ Ad embeddings update completed");
    } catch (error) {
      console.error("Error updating ad embeddings:", error);
      throw new Error(`Failed to update ad embeddings: ${error}`);
    }
  }
}

// Export singleton instance
export const vectorSearchService = VectorSearchService.getInstance();