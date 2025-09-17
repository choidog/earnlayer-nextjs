import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { apiKeys, users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import crypto from "crypto";

// Generate API key with earnlayer_ prefix
function generateApiKey(): string {
  return `earnlayer_${crypto.randomBytes(32).toString('hex')}`;
}

// POST /api/api-keys - Generate API key
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { userId, name = "Default API Key", permissions = {} } = body;

    if (!userId) {
      return NextResponse.json(
        { error: "Missing userId" },
        { status: 400 }
      );
    }

    // Verify user exists
    const user = await db.select().from(users).where(eq(users.id, userId)).limit(1);
    if (!user || user.length === 0) {
      return NextResponse.json(
        { error: "User not found" },
        { status: 404 }
      );
    }

    // Generate new API key
    const apiKey = generateApiKey();
    const newApiKey = {
      id: crypto.randomUUID(),
      name,
      key: apiKey,
      userId,
      permissions: permissions || { chat: ["read", "write"], api: ["read"] },
      metadata: {},
      rateLimit: { window: 60000, max: 1000 }, // 1000 requests per minute
    };

    const result = await db
      .insert(apiKeys)
      .values(newApiKey)
      .returning();

    return NextResponse.json({
      apiKey,
      id: result[0].id,
      name: result[0].name,
      userId: result[0].userId,
      permissions: result[0].permissions,
      createdAt: result[0].createdAt,
    });
  } catch (error) {
    console.error("Error generating API key:", error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}

// GET /api/api-keys - Get user's API keys
export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const userId = searchParams.get("userId");

    if (!userId) {
      return NextResponse.json(
        { error: "Missing userId parameter" },
        { status: 400 }
      );
    }

    const userApiKeys = await db
      .select({
        id: apiKeys.id,
        name: apiKeys.name,
        key: apiKeys.key,
        userId: apiKeys.userId,
        permissions: apiKeys.permissions,
        lastUsedAt: apiKeys.lastUsedAt,
        createdAt: apiKeys.createdAt,
      })
      .from(apiKeys)
      .where(eq(apiKeys.userId, userId));

    return NextResponse.json({
      apiKeys: userApiKeys,
    });
  } catch (error) {
    console.error("Error fetching API keys:", error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}