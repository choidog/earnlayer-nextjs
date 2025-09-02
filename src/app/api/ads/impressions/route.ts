import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { adImpressions } from "@/lib/db/schema";
import { z } from "zod";

const impressionRequestSchema = z.object({
  ad_id: z.string().uuid(),
  conversation_id: z.string().uuid(),
  impression_id: z.string(),
  ad_type: z.string(),
  placement: z.string(),
  similarity: z.number().optional(),
  context: z.string().optional(),
  metadata: z.record(z.any()).optional(),
});

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    console.log('🔍 [Impressions] Received request body:', body);
    const validatedData = impressionRequestSchema.parse(body);

    // Record the impression in the database
    const impression = await db
      .insert(adImpressions)
      .values({
        // id will be auto-generated as UUID
        adId: validatedData.ad_id,
        sessionId: validatedData.conversation_id,
        impressionType: validatedData.ad_type,
        adQueuePlacement: validatedData.placement,
        revenueAmount: "0", // Default for now
        creatorPayoutAmount: "0", // Default for now
        // Other fields will use defaults
      })
      .returning();

    console.log('✅ [Impressions] Recorded impression:', {
      impression_id: impression[0].id,
      ad_id: validatedData.ad_id,
      conversation_id: validatedData.conversation_id
    });

    return NextResponse.json({
      status: "success",
      impression_id: impression[0].id,
      recorded_at: impression[0].createdAt
    });

  } catch (error) {
    console.error("Error recording impression:", error);
    
    if (error instanceof z.ZodError) {
      console.log('❌ [Impressions] Validation failed:', error.errors);
      return NextResponse.json(
        { 
          error: "Invalid request data", 
          details: error.errors 
        },
        { status: 400 }
      );
    }

    return NextResponse.json(
      { error: "Failed to record impression" },
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
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    },
  });
}