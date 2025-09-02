import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { adClicks, adImpressions } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";

export async function GET(
  request: NextRequest,
  { params }: { params: Promise<{ impressionId: string }> }
) {
  try {
    const { impressionId } = await params;

    if (!impressionId) {
      return NextResponse.json(
        { error: "Impression ID is required" },
        { status: 400 }
      );
    }

    // Validate that the impression exists
    const impression = await db
      .select()
      .from(adImpressions)
      .where(eq(adImpressions.id, impressionId))
      .limit(1);

    if (impression.length === 0) {
      return NextResponse.json(
        { error: "Impression not found" },
        { status: 404 }
      );
    }

    // Record the click
    const click = await db
      .insert(adClicks)
      .values({
        impressionId: impressionId,
        clickMetadata: {
          userAgent: request.headers.get("user-agent") || undefined,
          timestamp: new Date().toISOString(),
          referer: request.headers.get("referer") || undefined,
        },
        isBilled: false, // Will be updated by billing process
      })
      .returning();

    console.log('✅ [Click Tracking] Recorded click:', {
      click_id: click[0].id,
      impression_id: impressionId,
      created_at: click[0].createdAt
    });

    return NextResponse.json({
      status: "success",
      click_id: click[0].id,
      impression_id: impressionId,
      recorded_at: click[0].createdAt
    });

  } catch (error) {
    console.error("Error recording click:", error);
    
    return NextResponse.json(
      { error: "Failed to record click" },
      { status: 500 }
    );
  }
}

// Handle preflight requests
export async function OPTIONS() {
  return new NextResponse(null, {
    status: 200,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    },
  });
}