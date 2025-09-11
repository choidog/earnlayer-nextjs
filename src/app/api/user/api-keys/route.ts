import { NextRequest, NextResponse } from "next/server";
import { auth } from "@/lib/auth/config";
import { db } from "@/lib/db/connection";
import { apikey } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

export async function GET(request: NextRequest) {
  try {
    // Get the authenticated user
    const session = await auth.api.getSession({
      headers: request.headers,
    });

    if (!session?.user) {
      return NextResponse.json(
        { error: "Authentication required" },
        { status: 401 }
      );
    }

    // Fetch user's API keys directly from database
    const userApiKeys = await db
      .select({
        id: apikey.id,
        name: apikey.name,
        key: apikey.key, // Get the actual key value
        enabled: apikey.enabled,
        rateLimitEnabled: apikey.rateLimitEnabled,
        rateLimitMax: apikey.rateLimitMax,
        rateLimitTimeWindow: apikey.rateLimitTimeWindow,
        requestCount: apikey.requestCount,
        remaining: apikey.remaining,
        lastRequest: apikey.lastRequest,
        expiresAt: apikey.expiresAt,
        createdAt: apikey.createdAt,
      })
      .from(apikey)
      .where(eq(apikey.userId, session.user.id))
      .orderBy(apikey.createdAt);

    // Format response with actual key values
    const formattedKeys = userApiKeys.map(key => ({
      id: key.id,
      name: key.name || 'Unnamed Key',
      key: key.key, // Return the full key value
      enabled: key.enabled,
      rateLimitEnabled: key.rateLimitEnabled,
      rateLimitMax: key.rateLimitMax,
      rateLimitTimeWindow: key.rateLimitTimeWindow,
      requestCount: key.requestCount || 0,
      remaining: key.remaining,
      lastRequest: key.lastRequest,
      expiresAt: key.expiresAt,
      createdAt: key.createdAt,
    }));

    return NextResponse.json({
      success: true,
      keys: formattedKeys,
      count: formattedKeys.length,
    });

  } catch (error) {
    console.error("Error fetching user API keys:", error);
    return NextResponse.json(
      { 
        error: "Failed to fetch API keys",
        details: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    );
  }
}

// Optional: Create new API key endpoint  
export async function POST(request: NextRequest) {
  try {
    const session = await auth.api.getSession({
      headers: request.headers,
    });

    if (!session?.user) {
      return NextResponse.json(
        { error: "Authentication required" },
        { status: 401 }
      );
    }

    const body = await request.json();
    const { name } = body;

    // Create new API key using Better Auth
    const newApiKey = await auth.api.createApiKey({
      userId: session.user.id,
      name: name || 'New API Key',
      expiresIn: 30 * 24 * 60 * 60 * 1000, // 30 days
    });

    return NextResponse.json({
      success: true,
      key: {
        id: newApiKey.keyId,
        name: name || 'New API Key',
        key: newApiKey.key, // Return the new key value
        enabled: true,
        createdAt: new Date().toISOString(),
      }
    });

  } catch (error) {
    console.error("Error creating API key:", error);
    return NextResponse.json(
      { 
        error: "Failed to create API key",
        details: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    );
  }
}