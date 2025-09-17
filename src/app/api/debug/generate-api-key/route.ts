import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { apiKeys } from "@/lib/db/schema";
import crypto from "crypto";

export async function POST(request: NextRequest) {
  try {
    console.log("🔧 [Debug] Generating API key for testing...");

    // Frontend auth: Generate API key directly
    const userId = "debug-user-" + Date.now();

    console.log("🔧 [Debug] Creating API key for user:", userId);

    // Generate API key
    const apiKey = `earnlayer_debug_${crypto.randomBytes(32).toString('hex')}`;
    const newApiKey = {
      id: crypto.randomUUID(),
      name: "Debug Test Key",
      key: apiKey,
      userId,
      permissions: { debug: ["read", "write"] },
      metadata: { type: "debug" },
      rateLimit: { window: 60000, max: 1000 },
    };

    const result = await db.insert(apiKeys).values(newApiKey).returning();
    
    console.log("✅ [Debug] API key created:", apiKey.substring(0, 20) + "...");

    return NextResponse.json({
      success: true,
      apiKey: apiKey,
      keyId: result[0].id,
      createdAt: result[0].createdAt,
      message: "API key generated for testing"
    });
    
  } catch (error) {
    console.error("❌ [Debug] Error generating API key:", error);
    return NextResponse.json(
      { 
        error: "Failed to generate API key",
        details: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    );
  }
}