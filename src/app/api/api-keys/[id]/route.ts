import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { apiKeys } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import crypto from "crypto";

// Generate API key with earnlayer_ prefix
function generateApiKey(): string {
  return `earnlayer_${crypto.randomBytes(32).toString('hex')}`;
}

// DELETE /api/api-keys/[id] - Delete API key
export async function DELETE(
  request: NextRequest,
  { params }: { params: { id: string } }
) {
  try {
    const { id } = params;

    const result = await db
      .delete(apiKeys)
      .where(eq(apiKeys.id, id))
      .returning();

    if (result.length === 0) {
      return NextResponse.json(
        { error: "API key not found" },
        { status: 404 }
      );
    }

    return NextResponse.json({
      success: true,
      message: "API key deleted successfully",
    });
  } catch (error) {
    console.error("Error deleting API key:", error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}

// POST /api/api-keys/[id] - Regenerate API key
export async function POST(
  request: NextRequest,
  { params }: { params: { id: string } }
) {
  try {
    const { id } = params;

    // Generate new API key
    const newKey = generateApiKey();

    const result = await db
      .update(apiKeys)
      .set({
        key: newKey,
        updatedAt: new Date(),
      })
      .where(eq(apiKeys.id, id))
      .returning();

    if (result.length === 0) {
      return NextResponse.json(
        { error: "API key not found" },
        { status: 404 }
      );
    }

    return NextResponse.json({
      apiKey: newKey,
      id: result[0].id,
      name: result[0].name,
      userId: result[0].userId,
      permissions: result[0].permissions,
      updatedAt: result[0].updatedAt,
    });
  } catch (error) {
    console.error("Error regenerating API key:", error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}