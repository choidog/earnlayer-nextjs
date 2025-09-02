import { NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { sql } from "drizzle-orm";

export async function GET() {
  try {
    // Test database connection
    await db.execute(sql`SELECT 1`);
    
    // Test OpenAI API key presence
    const hasOpenAI = !!process.env.OPENAI_API_KEY;
    
    return NextResponse.json({
      status: "healthy",
      timestamp: new Date().toISOString(),
      services: {
        database: "connected",
        openai: hasOpenAI ? "configured" : "missing",
        mcp_server: "available"
      },
      endpoints: {
        api: "/api/*",
        mcp: "/api/mcp/server",
        auth: "/api/auth/*"
      },
      version: "1.0.0"
    });
    
  } catch (error) {
    return NextResponse.json({
      status: "unhealthy", 
      error: error instanceof Error ? error.message : "Unknown error",
      timestamp: new Date().toISOString()
    }, { status: 503 });
  }
}