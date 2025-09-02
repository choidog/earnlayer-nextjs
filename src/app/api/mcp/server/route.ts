import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { 
  ads, 
  adCampaigns, 
  businessSettings, 
  chatSessions, 
  adImpressions,
  creators
} from "@/lib/db/schema";
import { eq, sql, and, isNull, isNotNull, desc } from "drizzle-orm";
import { z } from "zod";

// MCP Tool Schema
const mcpToolCallSchema = z.object({
  conversation_id: z.string().uuid(),
  queries: z.array(z.string()).min(1).max(3),
  user_message: z.string().optional(),
  include_demo_ads: z.boolean().default(false)
});

// Session storage for MCP sessions
const sessions = new Map<string, { initialized: boolean }>();

// Generate embeddings using OpenAI API
async function getEmbedding(text: string): Promise<number[]> {
  const response = await fetch('https://api.openai.com/v1/embeddings', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${process.env.OPENAI_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'text-embedding-3-small',
      input: [text],
    }),
  });

  if (!response.ok) {
    throw new Error(`OpenAI API error: ${response.statusText}`);
  }

  const data = await response.json();
  return data.data[0].embedding;
}

// Get creator ID from conversation ID
async function getCreatorIdFromConversation(conversationId: string): Promise<string | null> {
  try {
    const result = await db
      .select({ creatorId: chatSessions.creatorId })
      .from(chatSessions)
      .where(eq(chatSessions.id, conversationId))
      .limit(1);

    return result[0]?.creatorId || null;
  } catch (error) {
    console.error(`Error getting creator_id for conversation ${conversationId}:`, error);
    return null;
  }
}

// Load conversation ad settings with business settings fallback
async function loadConversationAdSettings(conversationId: string) {
  try {
    // Get creator ID from conversation
    const creatorId = await getCreatorIdFromConversation(conversationId);
    if (!creatorId) {
      return getDefaultAdSettings();
    }

    // Get business settings for creator
    const settings = await db
      .select()
      .from(businessSettings)
      .where(eq(businessSettings.creatorId, creatorId))
      .limit(1);

    if (settings.length > 0 && settings[0].isActive) {
      const setting = settings[0];
      return {
        creator_id: creatorId,
        ad_frequency: setting.adFrequency || 'normal',
        revenue_vs_relevance: parseFloat(setting.revenueVsRelevance || '0.5'),
        display_ad_similarity_threshold: parseFloat(setting.displayAdSimilarityThreshold || '-0.05'),
        min_seconds_between_display_ads: parseInt(setting.minSecondsBetweenDisplayAds || '30'),
        ad_types: null, // Show all ad types by default
        ad_categories: null // Show all categories by default
      };
    }

    return getDefaultAdSettings(creatorId);
  } catch (error) {
    console.error(`Error loading conversation ad settings for ${conversationId}:`, error);
    return getDefaultAdSettings();
  }
}

// Get default ad settings
function getDefaultAdSettings(creatorId?: string) {
  return {
    creator_id: creatorId || null,
    ad_frequency: 'normal',
    revenue_vs_relevance: 0.5,
    display_ad_similarity_threshold: -0.05,
    min_seconds_between_display_ads: 30,
    ad_types: null,
    ad_categories: null
  };
}

// Get affiliate code for creator-advertiser pair
async function getAffiliateCodeForAd(creatorId: string, advertiserId: string): Promise<string | null> {
  try {
    // Note: This table might not exist yet, so we'll return null for now
    // In the future, implement affiliate code lookup
    return null;
  } catch (error) {
    console.error(`Error getting affiliate code for creator ${creatorId} and advertiser ${advertiserId}:`, error);
    return null;
  }
}

// Append affiliate code to URL
function appendAffiliateCodeToUrl(url: string, affiliateCode: string): string {
  if (!affiliateCode) return url;
  
  if (url.includes('?')) {
    return `${url}&${affiliateCode}`;
  } else {
    return `${url}?${affiliateCode}`;
  }
}

// Search for hyperlink ads using vector similarity
async function searchHyperlinkAds(query: string, creatorId: string): Promise<any[]> {
  try {
    // Generate embedding for query
    const queryEmbedding = await getEmbedding(query);
    
    // Vector similarity search for hyperlink ads using proper Drizzle format
    const embeddingVector = `[${queryEmbedding.join(",")}]`;
    
    const results = await db
      .select({
        ad_id: ads.id,
        title: ads.title,
        url: ads.targetUrl,
        pricing_model: ads.pricingModel,
        description: ads.content,
        advertiser_id: adCampaigns.advertiserId,
        similarity: sql<number>`1 - (${ads.embedding} <-> ${embeddingVector}::vector)`.as("similarity"),
      })
      .from(ads)
      .innerJoin(adCampaigns, eq(adCampaigns.id, ads.campaignId))
      .where(
        and(
          sql`${ads.adType} IN ('hyperlink', 'text')`,
          eq(adCampaigns.status, 'active'),
          eq(ads.status, 'active'),
          isNull(ads.deletedAt),
          isNull(adCampaigns.deletedAt),
          isNotNull(ads.embedding)
        )
      )
      .orderBy(sql`${ads.embedding} <-> ${embeddingVector}::vector`)
      .limit(10);

    const adResults = [];
    for (const result of results) {
      let finalUrl = result.url as string;
      
      // Add affiliate code if this is an affiliate ad
      if (result.pricing_model === 'affiliate') {
        const affiliateCode = await getAffiliateCodeForAd(creatorId, result.advertiser_id as string);
        if (affiliateCode) {
          finalUrl = appendAffiliateCodeToUrl(finalUrl, affiliateCode);
          console.log(`[MCP_AFFILIATE] Added affiliate code '${affiliateCode}' to URL for ad '${result.title}'`);
        }
      }
      
      adResults.push({
        ad_id: result.ad_id as string,
        title: result.title as string,
        url: finalUrl,
        similarity: result.similarity,
        ad_type: 'hyperlink',
        description: result.description as string
      });
    }


    return adResults;
  } catch (error) {
    console.error(`Error searching hyperlink ads for query "${query}":`, error);
    return [];
  }
}

// Populate display ad queue
async function populateDisplayAdQueue(conversationId: string, creatorId: string, queries: string[], adSettings: any) {
  try {
    const displayAdTypes = ['popup', 'thinking', 'banner', 'video'];
    let totalAdsQueued = 0;

    for (const query of queries) {
      const queryEmbedding = await getEmbedding(query);
      
      for (const adType of displayAdTypes) {
        // Search for display ads of this type using proper Drizzle format
        const embeddingVector = `[${queryEmbedding.join(",")}]`;
        
        const results = await db
          .select({
            ad_id: ads.id,
            ad_type: ads.adType,
            similarity: sql<number>`1 - (${ads.embedding} <-> ${embeddingVector}::vector)`.as("similarity"),
          })
          .from(ads)
          .innerJoin(adCampaigns, eq(adCampaigns.id, ads.campaignId))
          .where(
            and(
              eq(ads.adType, adType as any),
              eq(ads.status, 'active'),
              eq(adCampaigns.status, 'active'),
              isNull(ads.deletedAt),
              isNull(adCampaigns.deletedAt),
              isNotNull(ads.embedding),
              sql`(1 - (${ads.embedding} <-> ${embeddingVector}::vector)) >= ${adSettings.display_ad_similarity_threshold}`
            )
          )
          .orderBy(sql`${ads.embedding} <-> ${embeddingVector}::vector`)
          .limit(3);

        console.log(`[MCP_DEBUG] Display ads for ${adType}: found ${results.length} results`);
        results.forEach((result, i) => {
          console.log(`  ${i+1}. ${result.ad_id} similarity: ${result.similarity.toFixed(4)}`);
        });

        totalAdsQueued += results.length;
      }
    }

    console.log(`[MCP_QUEUE] Populated ${totalAdsQueued} display ads for conversation ${conversationId}`);
    return totalAdsQueued;
  } catch (error) {
    console.error('Error populating display ad queue:', error);
    return 0;
  }
}

// Log MCP tool call analytics
async function logMcpToolCall(
  conversationId: string,
  creatorId: string,
  queries: string[],
  userMessage: string | null,
  hyperlinkAdsReturned: number,
  displayAdsQueued: number,
  processingTimeMs: number
): Promise<string | null> {
  try {
    // For now, just log to console
    // In the future, implement database logging
    console.log(`[MCP_ANALYTICS] conversation_id=${conversationId} creator_id=${creatorId} ` +
               `queries=${queries.length} hyperlink_ads=${hyperlinkAdsReturned} ` +
               `display_ads_queued=${displayAdsQueued} processing_time_ms=${processingTimeMs}`);
    
    return null;
  } catch (error) {
    console.error('[MCP_ANALYTICS] Error logging tool call analytics:', error);
    return null;
  }
}

// Main MCP server endpoint
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const sessionId = request.headers.get('Mcp-Session-Id') || crypto.randomUUID();

    console.log(`[MCP] Received request: ${body.method}`);

    // Handle MCP protocol methods
    switch (body.method) {
      case 'initialize':
        const params = body.params || {};
        const clientProtocolVersion = params.protocolVersion || '2024-11-05';
        const clientInfo = params.clientInfo || {};

        console.log(`[MCP_INIT] Initialize from ${clientInfo.name || 'unknown'} v${clientInfo.version || 'unknown'} using protocol ${clientProtocolVersion}`);

        // Store session
        sessions.set(sessionId, { initialized: false });

        const response = NextResponse.json({
          jsonrpc: '2.0',
          id: body.id,
          result: {
            protocolVersion: clientProtocolVersion,
            capabilities: {
              tools: {},
              resources: {},
              prompts: {},
              logging: {}
            },
            serverInfo: {
              name: 'EarnLayer Content & Ads Search',
              version: '1.0.0'
            }
          }
        });
        
        response.headers.set('Mcp-Session-Id', sessionId);
        return response;

      case 'notifications/initialized':
        if (sessions.has(sessionId)) {
          sessions.set(sessionId, { initialized: true });
        }
        return NextResponse.json({
          jsonrpc: '2.0',
          id: body.id,
          result: {}
        });

      case 'tools/list':
        console.log('[MCP_TOOLS] Handling tools/list request');
        return NextResponse.json({
          jsonrpc: '2.0',
          id: body.id,
          result: {
            tools: [
              {
                name: 'earnlayer_content_ads_search',
                description: 'Search for relevant ads based on user queries. Returns hyperlink ads directly and queues display ads for later serving.',
                inputSchema: {
                  type: 'object',
                  properties: {
                    conversation_id: {
                      type: 'string',
                      description: 'UUID of the conversation session'
                    },
                    queries: {
                      type: 'array',
                      items: { type: 'string' },
                      description: 'List of 1-3 search query strings',
                      minItems: 1,
                      maxItems: 3
                    },
                    user_message: {
                      type: 'string',
                      description: 'Optional original user message for tracking'
                    },
                    include_demo_ads: {
                      type: 'boolean',
                      description: 'Whether to include demo ads in results. Default: false'
                    }
                  },
                  required: ['conversation_id', 'queries']
                }
              }
            ]
          }
        });

      case 'tools/call':
        const toolParams = body.params || {};
        const toolName = toolParams.name;
        const arguments_ = toolParams.arguments || {};

        console.log(`[MCP_CALL] Handling tools/call for ${toolName} with arguments:`, arguments_);

        if (toolName !== 'earnlayer_content_ads_search') {
          return NextResponse.json({
            jsonrpc: '2.0',
            id: body.id,
            error: {
              code: -32602,
              message: 'Invalid tool name',
              data: { toolName }
            }
          });
        }

        // Validate arguments
        const validationResult = mcpToolCallSchema.safeParse(arguments_);
        if (!validationResult.success) {
          return NextResponse.json({
            jsonrpc: '2.0',
            id: body.id,
            error: {
              code: -32602,
              message: 'Invalid arguments',
              data: validationResult.error.errors
            }
          });
        }

        const { conversation_id, queries, user_message, include_demo_ads } = validationResult.data;
        
        const startTime = Date.now();
        let hyperlinkAdsReturned = 0;
        let displayAdsQueued = 0;

        try {
          // Load conversation settings
          const adSettings = await loadConversationAdSettings(conversation_id);
          const creatorId = adSettings.creator_id;

          if (!creatorId) {
            throw new Error(`Invalid conversation_id: ${conversation_id}`);
          }

          console.log(`[MCP_CALL] Found creator_id: ${creatorId}`);
          console.log(`[MCP_CALL] Ad settings: similarity_threshold=${adSettings.display_ad_similarity_threshold}, frequency=${adSettings.ad_frequency}`);

          // Search for hyperlink ads across all queries
          const allHyperlinkAds = [];
          const queryResults = [];

          for (const query of queries) {
            const hyperlinkAds = await searchHyperlinkAds(query, creatorId);
            const filteredAds = hyperlinkAds.filter(ad => 
              ad.similarity >= -0.05 // Accept up to 5% dissimilarity 
            );
            
            allHyperlinkAds.push(...filteredAds);
            queryResults.push({
              query,
              hyperlink_ads: filteredAds
            });
          }

          // Deduplicate and take top 3 hyperlink ads
          const uniqueAds = Array.from(
            new Map(allHyperlinkAds.map(ad => [ad.url, ad])).values()
          );
          uniqueAds.sort((a, b) => b.similarity - a.similarity);
          const top3HyperlinkAds = uniqueAds.slice(0, 3);
          hyperlinkAdsReturned = top3HyperlinkAds.length;

          // Populate display ad queue
          displayAdsQueued = await populateDisplayAdQueue(conversation_id, creatorId, queries, adSettings);

          // Calculate processing time
          const processingTimeMs = Date.now() - startTime;

          // Log analytics
          await logMcpToolCall(
            conversation_id,
            creatorId,
            queries,
            user_message || null,
            hyperlinkAdsReturned,
            displayAdsQueued,
            processingTimeMs
          );

          // Format response
          const finalResponse = {
            results: queryResults.map(result => ({
              query: result.query,
              hyperlink_ads: result.hyperlink_ads.filter(ad => 
                top3HyperlinkAds.some(topAd => topAd.ad_id === ad.ad_id)
              )
            })),
            summary: {
              conversation_id,
              total_queries: queries.length,
              hyperlink_ads_returned: hyperlinkAdsReturned,
              display_ads_queued: displayAdsQueued,
              processing_time_ms: processingTimeMs
            }
          };

          if (top3HyperlinkAds.length > 0) {
            const adsSummary = top3HyperlinkAds.map(ad => `${ad.title} -> ${ad.url}`).join(', ');
            console.log(`[MCP_RESPONSE] Returning ${hyperlinkAdsReturned} hyperlink ads: ${adsSummary}`);
          } else {
            console.log('[MCP_RESPONSE] No hyperlink ads found');
          }

          console.log(`[MCP_RESPONSE] Display ads queued: ${displayAdsQueued}`);

          return NextResponse.json({
            jsonrpc: '2.0',
            id: body.id,
            result: {
              content: [
                {
                  type: 'text',
                  text: JSON.stringify(finalResponse, null, 2)
                }
              ]
            }
          });

        } catch (toolError) {
          console.error('[MCP_CALL] Tool execution error:', toolError);
          return NextResponse.json({
            jsonrpc: '2.0',
            id: body.id,
            error: {
              code: -32603,
              message: 'Tool execution failed',
              data: String(toolError)
            }
          });
        }

      case 'ping':
        return NextResponse.json({
          jsonrpc: '2.0',
          id: body.id,
          result: {}
        });

      default:
        return NextResponse.json({
          jsonrpc: '2.0',
          id: body.id,
          error: {
            code: -32601,
            message: 'Method not found',
            data: { method: body.method }
          }
        });
    }

  } catch (error) {
    console.error('Error handling MCP request:', error);
    return NextResponse.json({
      jsonrpc: '2.0',
      id: null,
      error: {
        code: -32603,
        message: 'Internal error',
        data: String(error)
      }
    }, { status: 500 });
  }
}

// GET endpoint for health check and server info
export async function GET(request: NextRequest) {
  return NextResponse.json({
    server: "EarnLayer MCP Server",
    version: "1.0.0",
    status: "running",
    transport: "http",
    endpoints: {
      tools_list: "POST /api/mcp/server (method: tools/list)",
      tools_call: "POST /api/mcp/server (method: tools/call)",
    },
    tools: [
      "earnlayer_content_ads_search"
    ],
    timestamp: new Date().toISOString()
  });
}

// Handle preflight requests
export async function OPTIONS() {
  return new NextResponse(null, {
    status: 200,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization, Mcp-Session-Id',
    },
  });
}