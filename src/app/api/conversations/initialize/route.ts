import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { chatSessions, creators } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";

const initializeRequestSchema = z.object({
  creator_id: z.string().uuid().optional(),
  visitor_uuid: z.string().nullable().optional(),
  ad_preferences: z.record(z.any()).optional(),
  context: z.string().optional(),
  metadata: z.record(z.any()).optional(),
});

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const validatedData = initializeRequestSchema.parse(body);

    // Get creator (use specified creator or get first available creator)
    let creatorId = validatedData.creator_id;
    let creator;

    if (creatorId) {
      creator = await db
        .select()
        .from(creators)
        .where(eq(creators.id, creatorId))
        .limit(1);
    } else {
      // Get first available creator
      creator = await db
        .select()
        .from(creators)
        .limit(1);
      
      if (creator.length > 0) {
        creatorId = creator[0].id;
      }
    }

    if (creator.length === 0) {
      return NextResponse.json(
        { error: creatorId ? "Creator not found" : "No creators available" },
        { status: 404 }
      );
    }

    // Create new chat session
    const session = await db
      .insert(chatSessions)
      .values({
        creatorId: creatorId,
        startedAt: new Date(),
        metadata: {
          visitor_uuid: validatedData.visitor_uuid,
          ad_preferences: validatedData.ad_preferences,
          context: validatedData.context,
          ...validatedData.metadata,
        },
      })
      .returning();

    const createdSession = session[0];

    // Default ad settings (could be customized per creator)
    const adSettings = {
      display_ad_enabled: true,
      display_ad_frequency: 5, // Every 5 messages
      display_ad_similarity_threshold: 0.25,
      hyperlink_ad_enabled: true,
      hyperlink_ad_similarity_threshold: 0.3,
      ad_types: ["hyperlink", "banner", "text"],
      placements: ["sidebar", "chat_inline", "default"],
    };

    return NextResponse.json({
      conversation_id: createdSession.id,
      creator_id: creatorId,
      ad_settings: adSettings,
      status: "initialized",
      created_at: createdSession.startedAt.toISOString(),
    });

  } catch (error) {
    console.error("Error initializing conversation:", error);
    
    if (error instanceof z.ZodError) {
      return NextResponse.json(
        { 
          error: "Invalid request data", 
          details: error.errors 
        },
        { status: 400 }
      );
    }

    return NextResponse.json(
      { error: "Failed to initialize conversation" },
      { status: 500 }
    );
  }
}

export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const sessionId = searchParams.get('session_id');

  if (!sessionId) {
    return NextResponse.json(
      { error: "session_id parameter is required" },
      { status: 400 }
    );
  }

  try {
    const session = await db
      .select()
      .from(chatSessions)
      .where(eq(chatSessions.id, sessionId))
      .limit(1);

    if (session.length === 0) {
      return NextResponse.json(
        { error: "Session not found" },
        { status: 404 }
      );
    }

    const sessionData = session[0];

    return NextResponse.json({
      conversation_id: sessionData.id,
      creator_id: sessionData.creatorId,
      status: sessionData.endedAt ? "ended" : "active",
      started_at: sessionData.startedAt.toISOString(),
      ended_at: sessionData.endedAt?.toISOString(),
      metadata: sessionData.metadata,
    });

  } catch (error) {
    console.error("Error getting conversation:", error);
    return NextResponse.json(
      { error: "Failed to get conversation" },
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
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
    },
  });
}