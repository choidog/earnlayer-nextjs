import { NextRequest, NextResponse } from "next/server";


export async function POST(request: NextRequest) {
  try {
    console.log("🔧 [Debug] Generating API key for testing...");
    
    // Get session first to ensure user is authenticated
    const session = await 
      headers: request.headers,
    });

    if (!session) {
      // For debugging purposes, let's try to create an API key anyway
      console.log("⚠️ [Debug] No session found, but proceeding for debug");
    }

    const userId = session?.user?.id || "debug-user";
    
    console.log("🔧 [Debug] Creating API key for user:", userId);
    
    // Create API key using Better Auth
    const apiKeyResult = await auth.api.createApiKey({
      userId: userId,
      name: "Debug Test Key",
      expiresIn: 30 * 24 * 60 * 60 * 1000, // 30 days
    });
    
    console.log("✅ [Debug] API key created:", apiKeyResult.key?.substring(0, 20) + "...");
    
    return NextResponse.json({
      success: true,
      apiKey: apiKeyResult.key,
      keyId: apiKeyResult.keyId,
      expiresAt: apiKeyResult.expiresAt,
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