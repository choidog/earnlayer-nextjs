import { mcpServer } from "../src/lib/mcp/server";
import { config } from "dotenv";

// Load environment variables
config({ path: ".env.local" });

async function testMCPServer() {
  console.log("🧪 Testing EarnLayer MCP Server\n");

  try {
    console.log("1️⃣  Testing MCP server initialization...");
    const server = mcpServer.getServer();
    console.log("✅ MCP server initialized successfully");
    
    // Check if server has the expected structure
    console.log(`   Server type: ${typeof server}`);
    console.log(`   Server methods: ${Object.getOwnPropertyNames(Object.getPrototypeOf(server)).join(", ")}`);
    
    console.log("\n2️⃣  Testing tool registration...");
    // Access internal tool registry if available
    // @ts-ignore
    const toolHandlers = server._requestHandlers?.get("tools/list");
    // @ts-ignore 
    const callHandlers = server._requestHandlers?.get("tools/call");
    
    if (toolHandlers) {
      console.log("✅ Tools list handler registered");
    }
    
    if (callHandlers) {
      console.log("✅ Tools call handler registered");
    }
    
    console.log("\n3️⃣  Testing service dependencies...");
    
    // Test embedding service
    const { embeddingService } = await import("../src/lib/services/embeddings");
    const testEmbedding = await embeddingService.generateEmbedding("test message");
    console.log(`✅ Embedding service working (${testEmbedding.length} dimensions)`);
    
    // Test ad serving service
    const { adServingService } = await import("../src/lib/services/ad-serving");
    console.log("✅ Ad serving service loaded");
    
    console.log("\n4️⃣  Testing environment configuration...");
    console.log(`   DATABASE_URL configured: ${process.env.DATABASE_URL ? "Yes" : "No"}`);
    console.log(`   OPENAI_API_KEY configured: ${process.env.OPENAI_API_KEY && !process.env.OPENAI_API_KEY.includes("placeholder") ? "Yes" : "No (using mocks)"}`);
    
    console.log("\n🎉 MCP server validation completed!");

  } catch (error) {
    console.error("❌ MCP server test failed:", error);
    
    if (error instanceof Error) {
      console.error("   Error details:", error.message);
      console.error("   Stack trace:", error.stack);
    }
    
    // Check common issues
    console.log("\n🔍 Troubleshooting tips:");
    console.log("   - Ensure DATABASE_URL is configured in .env.local");
    console.log("   - Ensure OPENAI_API_KEY is configured in .env.local");
    console.log("   - Check that the conversation ID exists in your database");
    console.log("   - Verify database connection and schema");
    
    process.exit(1);
  }
}

// Run MCP server validation
testMCPServer();