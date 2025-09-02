/**
 * Demo MCP Client for EarnLayer
 * 
 * This demonstrates how external agents (like Claude Desktop, OpenRouter, etc.)
 * can integrate with the EarnLayer MCP server to get contextual ads.
 */

import { config } from "dotenv";

// Load environment variables
config({ path: ".env.local" });

interface MCPRequest {
  jsonrpc: "2.0";
  id: number;
  method: string;
  params: any;
}

interface MCPResponse {
  jsonrpc: "2.0";
  id: number;
  result?: any;
  error?: {
    code: number;
    message: string;
  };
}

class EarnLayerMCPClient {
  private baseUrl: string;
  private requestId = 1;

  constructor(baseUrl: string = "http://localhost:3000/api/mcp/server") {
    this.baseUrl = baseUrl;
  }

  private async makeRequest(method: string, params: any): Promise<any> {
    const request: MCPRequest = {
      jsonrpc: "2.0",
      id: this.requestId++,
      method,
      params
    };

    console.log(`🔄 Making MCP request: ${method}`);
    console.log(`   Params:`, JSON.stringify(params, null, 2));

    const response = await fetch(this.baseUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify(request),
    });

    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${response.statusText}`);
    }

    const result: MCPResponse = await response.json();

    if (result.error) {
      throw new Error(`MCP Error ${result.error.code}: ${result.error.message}`);
    }

    return result.result;
  }

  async listTools() {
    return await this.makeRequest("tools/list", {});
  }

  async callTool(name: string, args: any) {
    return await this.makeRequest("tools/call", {
      name,
      arguments: args
    });
  }

  // Convenience methods for specific tools
  async searchContentAds(
    conversationId: string,
    queries: string[],
    options: {
      userMessage?: string;
      includeDemoAds?: boolean;
      adPreferences?: {
        adTypes?: string[];
        similarityThreshold?: number;
        maxAds?: number;
      };
    } = {}
  ) {
    return await this.callTool("earnlayer_content_ads_search", {
      conversation_id: conversationId,
      queries,
      user_message: options.userMessage,
      include_demo_ads: options.includeDemoAds || false,
      ad_preferences: options.adPreferences || {}
    });
  }

  async getDisplayAds(
    conversationId: string,
    options: {
      placement?: string;
      adType?: string;
    } = {}
  ) {
    return await this.callTool("earnlayer_get_display_ads", {
      conversation_id: conversationId,
      placement: options.placement || "sidebar",
      ad_type: options.adType || "banner"
    });
  }
}

// Demo scenarios
async function runDemo() {
  console.log("🎭 EarnLayer MCP Client Demo\n");

  const client = new EarnLayerMCPClient();

  try {
    // Demo data - replace with real conversation ID from your database
    const conversationId = "550e8400-e29b-41d4-a716-446655440000";
    
    console.log("📋 Demo Configuration:");
    console.log(`   Conversation ID: ${conversationId}`);
    console.log(`   MCP Server URL: ${client['baseUrl']}\n`);

    // Scenario 1: List available tools
    console.log("🔍 Scenario 1: Discovering available tools");
    console.log("=" .repeat(50));
    
    const tools = await client.listTools();
    console.log("✅ Available tools:");
    tools.tools.forEach((tool: any) => {
      console.log(`   📦 ${tool.name}`);
      console.log(`      ${tool.description}`);
      console.log(`      Required: ${tool.inputSchema.required?.join(", ") || "none"}`);
    });
    console.log("");

    // Scenario 2: AI Assistant requesting contextual ads
    console.log("🤖 Scenario 2: AI Assistant requesting contextual ads");
    console.log("=" .repeat(50));
    
    const userQuery = "I need help with cloud infrastructure and DevOps tools";
    const searchQueries = ["cloud infrastructure", "DevOps tools", "AWS services"];
    
    console.log(`👤 User message: "${userQuery}"`);
    console.log(`🔍 Generated search queries: ${searchQueries.join(", ")}`);
    
    const searchResult = await client.searchContentAds(conversationId, searchQueries, {
      userMessage: userQuery,
      includeDemoAds: true,
      adPreferences: {
        similarityThreshold: 0.3,
        maxAds: 3
      }
    });
    
    console.log("📄 Ad search result:");
    console.log(searchResult.content[0].text);
    console.log("");

    // Scenario 3: Getting display ads for UI integration
    console.log("🖼️  Scenario 3: Getting display ads for UI");
    console.log("=" .repeat(50));
    
    const displayResult = await client.getDisplayAds(conversationId, {
      placement: "sidebar",
      adType: "banner"
    });
    
    console.log("🎨 Display ad result:");
    console.log(displayResult.content[0].text);
    console.log("");

    // Scenario 4: E-commerce chatbot integration
    console.log("🛒 Scenario 4: E-commerce chatbot integration");
    console.log("=" .repeat(50));
    
    const ecommerceQuery = "Looking for project management software for my team";
    const ecommerceSearches = ["project management software", "team collaboration tools"];
    
    console.log(`🛍️  E-commerce query: "${ecommerceQuery}"`);
    
    const ecommerceResult = await client.searchContentAds(conversationId, ecommerceSearches, {
      userMessage: ecommerceQuery,
      adPreferences: {
        adTypes: ["hyperlink"],
        similarityThreshold: 0.25,
        maxAds: 5
      }
    });
    
    console.log("💰 E-commerce ad recommendations:");
    console.log(ecommerceResult.content[0].text);
    console.log("");

    // Scenario 5: Error handling demonstration
    console.log("⚠️  Scenario 5: Error handling");
    console.log("=" .repeat(50));
    
    try {
      await client.callTool("nonexistent_tool", {});
    } catch (error) {
      console.log("✅ Error handled correctly:");
      console.log(`   ${error instanceof Error ? error.message : error}`);
    }
    console.log("");

    console.log("🎉 All demo scenarios completed successfully!");
    console.log("\n📚 Integration Guide:");
    console.log("   1. Use listTools() to discover available capabilities");
    console.log("   2. Call searchContentAds() for contextual ad recommendations");
    console.log("   3. Call getDisplayAds() for UI-specific ad placements");
    console.log("   4. Handle errors gracefully for robust integration");
    console.log("   5. Monitor response times and adjust similarity thresholds");

  } catch (error) {
    console.error("❌ Demo failed:", error);
    
    if (error instanceof Error) {
      console.error("   Details:", error.message);
    }
    
    console.log("\n🔧 Troubleshooting:");
    console.log("   - Ensure the Next.js server is running (npm run dev)");
    console.log("   - Check that DATABASE_URL is configured");
    console.log("   - Verify the conversation ID exists");
    console.log("   - Confirm MCP server endpoint is accessible");
    
    process.exit(1);
  }
}

// Integration examples for different platforms
function printIntegrationExamples() {
  console.log("\n📖 Platform Integration Examples:");
  console.log("=" .repeat(50));

  console.log("\n🖥️  Claude Desktop Configuration:");
  console.log(`
Add to your Claude Desktop config:
{
  "mcpServers": {
    "earnlayer": {
      "command": "npm",
      "args": ["run", "mcp:server"],
      "cwd": "/path/to/earnlayer-nextjs"
    }
  }
}
  `);

  console.log("🌐 OpenRouter/API Integration:");
  console.log(`
const mcpClient = new EarnLayerMCPClient("https://your-domain.railway.app/api/mcp/server");

// In your chat handler:
const ads = await mcpClient.searchContentAds(conversationId, ["user query"], {
  adPreferences: { maxAds: 3, similarityThreshold: 0.3 }
});
  `);

  console.log("🤖 Custom Agent Integration:");
  console.log(`
// Add to your agent's tool definitions
const tools = await mcpClient.listTools();

// Use in conversation flow
if (shouldShowAds(userMessage)) {
  const ads = await mcpClient.searchContentAds(sessionId, extractQueries(userMessage));
  return formatResponse(aiResponse, ads);
}
  `);
}

// Main execution
if (require.main === module) {
  runDemo()
    .then(() => {
      printIntegrationExamples();
    })
    .catch((error) => {
      console.error("💥 Unhandled error:", error);
      process.exit(1);
    });
}

export { EarnLayerMCPClient };