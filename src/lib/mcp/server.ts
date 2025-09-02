import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
  TextContent,
  CallToolResult,
} from "@modelcontextprotocol/sdk/types.js";
import { db } from "@/lib/db/connection";
import { adServingService } from "@/lib/services/ad-serving";
import { embeddingService } from "@/lib/services/embeddings";
import { chatSessions, chatMessages } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

export interface MCPAdResult {
  id: string;
  title: string;
  url: string;
  snippet: string;
  similarity: number;
  ad_type: string;
  revenue: number;
}

export interface MCPToolCallResult {
  hyperlink_ads: MCPAdResult[];
  display_ads_queued: number;
  total_queries_processed: number;
  conversation_id: string;
  creator_id: string;
  processing_time_ms: number;
}

export class EarnLayerMCPServer {
  private server: Server;

  constructor() {
    this.server = new Server(
      {
        name: "earnlayer-ads-server",
        version: "1.0.0",
      },
      {
        capabilities: {
          tools: {},
        },
      }
    );

    this.setupToolHandlers();
  }

  private setupToolHandlers() {
    // List available tools
    this.server.setRequestHandler(ListToolsRequestSchema, async () => {
      return {
        tools: [
          {
            name: "earnlayer_content_ads_search",
            description: "Search for relevant ads based on user queries. Returns hyperlink ads directly and queues display ads for later serving.",
            inputSchema: {
              type: "object",
              properties: {
                conversation_id: {
                  type: "string",
                  description: "UUID of the conversation session"
                },
                queries: {
                  type: "array",
                  items: { type: "string" },
                  description: "List of 1-3 search query strings",
                  minItems: 1,
                  maxItems: 3
                },
                user_message: {
                  type: "string",
                  description: "Optional original user message for tracking"
                },
                include_demo_ads: {
                  type: "boolean",
                  description: "Whether to include demo ads in results. Default: false",
                  default: false
                },
                ad_preferences: {
                  type: "object",
                  description: "Optional ad preferences override",
                  properties: {
                    ad_types: {
                      type: "array",
                      items: { type: "string" },
                      description: "Allowed ad types (hyperlink, banner, popup, etc.)"
                    },
                    similarity_threshold: {
                      type: "number",
                      minimum: 0,
                      maximum: 1,
                      description: "Minimum similarity threshold for ads"
                    },
                    max_ads: {
                      type: "number",
                      minimum: 1,
                      maximum: 10,
                      description: "Maximum number of ads to return"
                    }
                  }
                }
              },
              required: ["conversation_id", "queries"]
            }
          } as Tool,
          {
            name: "earnlayer_get_display_ads",
            description: "Get display ads for a conversation session based on recent context",
            inputSchema: {
              type: "object",
              properties: {
                conversation_id: {
                  type: "string",
                  description: "UUID of the conversation session"
                },
                placement: {
                  type: "string",
                  description: "Ad placement location",
                  enum: ["sidebar", "banner", "popup", "inline"],
                  default: "sidebar"
                },
                ad_type: {
                  type: "string", 
                  description: "Type of display ad requested",
                  enum: ["banner", "popup", "video", "thinking"],
                  default: "banner"
                }
              },
              required: ["conversation_id"]
            }
          } as Tool,
        ],
      };
    });

    // Handle tool calls
    this.server.setRequestHandler(CallToolRequestSchema, async (request) => {
      const { name, arguments: args } = request.params;

      switch (name) {
        case "earnlayer_content_ads_search":
          return await this.handleContentAdsSearch(args);
        case "earnlayer_get_display_ads":
          return await this.handleGetDisplayAds(args);
        default:
          throw new Error(`Unknown tool: ${name}`);
      }
    });
  }

  private async handleContentAdsSearch(args: any): Promise<CallToolResult> {
    const startTime = Date.now();
    
    try {
      const {
        conversation_id,
        queries = [],
        user_message,
        include_demo_ads = false,
        ad_preferences = {}
      } = args;

      if (!conversation_id) {
        throw new Error("conversation_id is required");
      }
      if (!queries || queries.length === 0) {
        throw new Error("At least one query is required");
      }
      if (queries.length > 3) {
        throw new Error("Maximum 3 queries allowed");
      }

      console.log(`[MCP_CALL] Starting processing for conversation ${conversation_id}`);
      console.log(`[MCP_CALL] Queries (${queries.length}): ${queries}`);

      // Get session and creator info
      const session = await db
        .select()
        .from(chatSessions)
        .where(eq(chatSessions.id, conversation_id))
        .limit(1);

      if (session.length === 0) {
        throw new Error(`Conversation not found: ${conversation_id}`);
      }

      const sessionData = session[0];
      const creatorId = sessionData.creatorId;

      if (!creatorId) {
        throw new Error(`No creator found for conversation: ${conversation_id}`);
      }

      console.log(`[MCP_CALL] Found creator_id: ${creatorId}`);

      // Process all queries and collect hyperlink ads
      const allHyperlinkAds: MCPAdResult[] = [];
      let displayAdsQueued = 0;

      for (const query of queries) {
        console.log(`[MCP_QUERY] Processing query: "${query}"`);

        // Get contextual ads for this query
        const adResult = await adServingService.serveContextualAds(query, {
          creatorId,
          sessionId: conversation_id,
          adType: "hyperlink",
          limit: ad_preferences.max_ads || 5,
          similarityThreshold: ad_preferences.similarity_threshold || 0.25,
        });

        // Convert to MCP format
        const mcpAds = adResult.ads.map(ad => ({
          id: ad.id,
          title: ad.title,
          url: ad.targetUrl || "#",
          snippet: ad.content.substring(0, 150) + (ad.content.length > 150 ? "..." : ""),
          similarity: ad.similarity,
          ad_type: ad.adType,
          revenue: ad.revenue,
        }));

        allHyperlinkAds.push(...mcpAds);

        // Also queue display ads for later serving
        const displayAdResult = await adServingService.serveContextualAds(query, {
          creatorId,
          sessionId: conversation_id,
          adType: "banner", // Display ads are typically banners
          limit: 3,
          similarityThreshold: 0.2, // Lower threshold for display ads
        });

        displayAdsQueued += displayAdResult.ads.length;
      }

      // Deduplicate and get top ads
      const uniqueAds = this.deduplicateAds(allHyperlinkAds);
      const topAds = uniqueAds
        .sort((a, b) => b.similarity - a.similarity)
        .slice(0, ad_preferences.max_ads || 3);

      console.log(`[MCP_RESULT] Returning ${topAds.length} hyperlink ads, ${displayAdsQueued} display ads queued`);

      // Store user message if provided
      if (user_message) {
        const embedding = await embeddingService.generateEmbedding(user_message);
        await db.insert(chatMessages).values({
          sessionId: conversation_id,
          content: user_message,
          role: "user",
          createdAt: new Date(),
          embedding: `[${embedding.join(",")}]` as any,
        });
      }

      // Format response for MCP
      const processingTime = Date.now() - startTime;
      
      const result: MCPToolCallResult = {
        hyperlink_ads: topAds,
        display_ads_queued: displayAdsQueued,
        total_queries_processed: queries.length,
        conversation_id,
        creator_id: creatorId,
        processing_time_ms: processingTime,
      };

      // Format as markdown for the LLM
      const markdownResponse = this.formatAdsAsMarkdown(topAds, result);

      return {
        content: [
          {
            type: "text",
            text: markdownResponse,
          } as TextContent,
        ],
      };

    } catch (error) {
      console.error("[MCP_ERROR] Content ads search failed:", error);
      return {
        content: [
          {
            type: "text",
            text: `Error: ${error instanceof Error ? error.message : "Unknown error"}`,
          } as TextContent,
        ],
        isError: true,
      };
    }
  }

  private async handleGetDisplayAds(args: any): Promise<CallToolResult> {
    try {
      const {
        conversation_id,
        placement = "sidebar",
        ad_type = "banner"
      } = args;

      if (!conversation_id) {
        throw new Error("conversation_id is required");
      }

      console.log(`[MCP_DISPLAY] Getting display ads for conversation ${conversation_id}`);

      // Get session info
      const session = await db
        .select()
        .from(chatSessions)
        .where(eq(chatSessions.id, conversation_id))
        .limit(1);

      if (session.length === 0) {
        throw new Error(`Conversation not found: ${conversation_id}`);
      }

      const sessionData = session[0];
      const creatorId = sessionData.creatorId;

      if (!creatorId) {
        throw new Error(`No creator found for conversation: ${conversation_id}`);
      }

      // Get display ads based on conversation history
      const adResult = await adServingService.serveConversationAds(conversation_id, {
        creatorId,
        sessionId: conversation_id,
        adType: ad_type as any,
        placement: placement as any,
        limit: 3,
        similarityThreshold: 0.25,
        contextualMessages: 10,
      });

      // Format response
      const displayAds = adResult.ads.map(ad => ({
        id: ad.id,
        title: ad.title,
        url: ad.targetUrl || "#",
        snippet: ad.content,
        similarity: ad.similarity,
        ad_type: ad.adType,
        revenue: ad.revenue,
      }));

      const markdownResponse = this.formatDisplayAdsAsMarkdown(displayAds, placement);

      return {
        content: [
          {
            type: "text",
            text: markdownResponse,
          } as TextContent,
        ],
      };

    } catch (error) {
      console.error("[MCP_ERROR] Display ads fetch failed:", error);
      return {
        content: [
          {
            type: "text",
            text: `Error: ${error instanceof Error ? error.message : "Unknown error"}`,
          } as TextContent,
        ],
        isError: true,
      };
    }
  }

  private deduplicateAds(ads: MCPAdResult[]): MCPAdResult[] {
    const seen = new Set<string>();
    return ads.filter(ad => {
      const key = ad.url.toLowerCase();
      if (seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    });
  }

  private formatAdsAsMarkdown(ads: MCPAdResult[], result: MCPToolCallResult): string {
    if (ads.length === 0) {
      return `No relevant ads found for the queries. ${result.display_ads_queued} display ads have been queued for later serving.`;
    }

    let markdown = `Found ${ads.length} relevant ads:\n\n`;
    
    for (const ad of ads) {
      markdown += `- **[${ad.title}](${ad.url})** (${(ad.similarity * 100).toFixed(1)}% relevance)\n`;
      markdown += `  ${ad.snippet}\n\n`;
    }

    markdown += `\n*${result.display_ads_queued} display ads queued • Processed ${result.total_queries_processed} queries in ${result.processing_time_ms}ms*`;

    return markdown;
  }

  private formatDisplayAdsAsMarkdown(ads: MCPAdResult[], placement: string): string {
    if (ads.length === 0) {
      return `No display ads available for placement: ${placement}`;
    }

    let markdown = `Display ads for ${placement}:\n\n`;
    
    for (const ad of ads) {
      markdown += `- **${ad.title}** (${(ad.similarity * 100).toFixed(1)}% relevance)\n`;
      markdown += `  ${ad.snippet}\n`;
      markdown += `  [View Ad](${ad.url})\n\n`;
    }

    return markdown;
  }

  public getServer(): Server {
    return this.server;
  }

  public async start(transport: any): Promise<void> {
    await this.server.connect(transport);
    console.log("🚀 EarnLayer MCP Server started");
  }
}

// Export singleton instance
export const mcpServer = new EarnLayerMCPServer();