#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { mcpServer } from "../lib/mcp/server.js";
import { config } from "dotenv";

// Load environment variables only in development
if (process.env.NODE_ENV !== "production") {
  config({ path: ".env.local" });
}

async function main() {
  console.error("🚀 Starting EarnLayer MCP Server (standalone)");
  
  // Create stdio transport for standard MCP client compatibility
  const transport = new StdioServerTransport();
  
  try {
    await mcpServer.start(transport);
    console.error("✅ MCP Server running on stdio transport");
    
    // Keep the process running
    process.on('SIGINT', () => {
      console.error("🛑 Received SIGINT, shutting down gracefully");
      process.exit(0);
    });

    process.on('SIGTERM', () => {
      console.error("🛑 Received SIGTERM, shutting down gracefully");
      process.exit(0);
    });

  } catch (error) {
    console.error("❌ Failed to start MCP server:", error);
    process.exit(1);
  }
}

// Run the server
if (require.main === module) {
  main().catch((error) => {
    console.error("💥 Unhandled error:", error);
    process.exit(1);
  });
}