import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { chatSessions, creators } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";
import { auth } from "@/lib/auth/config";
import crypto from "crypto";

const initializeRequestSchema = z.object({
  creator_id: z.string().uuid().optional(), // Legacy support  
  user_id: z.string().optional(), // Better Auth user ID (preferred)
  user_email: z.string().email().optional(), // User email for creator auto-creation
  user_name: z.string().optional(), // User name for creator auto-creation
  session_id: z.string().optional(), // Session ID for conversation tracking
  visitor_uuid: z.string().nullable().optional(),
  ad_preferences: z.record(z.any()).optional(),
  context: z.string().optional(),
  metadata: z.record(z.any()).optional(),
});

// Helper function to generate unique creator name
function generateCreatorName(email: string, name?: string): string {
  if (name) {
    return `${name} (${email.split('@')[0]})`;
  }
  const emailPrefix = email.split('@')[0];
  const randomSuffix = crypto.randomBytes(3).toString('hex');
  return `Creator ${emailPrefix}_${randomSuffix}`;
}

export async function POST(request: NextRequest) {
  try {
    console.log("🚀 [INIT] Starting conversation initialization...");
    
    const body = await request.json();
    console.log("📋 [INIT] Request body:", JSON.stringify(body, null, 2));
    
    const validatedData = initializeRequestSchema.parse(body);

    // Get Better Auth session for auto-creator creation (optional fallback)
    let session = null;
    try {
      session = await auth.api.getSession({
        headers: request.headers,
      });
    } catch (error) {
      console.log("⚠️ [INIT] No authenticated session found");
    }

    // Get creator (support both user_id and legacy creator_id with auto-creation)
    let creatorId = validatedData.creator_id;
    let creator;

    if (validatedData.user_id) {
      // Preferred: lookup by user_id with auto-creation
      console.log("🔍 [INIT] Looking up creator by user_id:", validatedData.user_id);
      creator = await db
        .select()
        .from(creators)
        .where(eq(creators.userId, validatedData.user_id))
        .limit(1);
        
      if (creator.length > 0) {
        creatorId = creator[0].id;
        console.log("✅ [INIT] Found existing creator by user_id:", { creatorId, userId: validatedData.user_id });
      } else {
        // Auto-create creator profile
        console.log("🎯 [INIT] Auto-creating creator profile for user_id:", validatedData.user_id);
        
        // Use provided user data or fall back to session data
        let userEmail = validatedData.user_email;
        let userName = validatedData.user_name;
        
        if (!userEmail && session) {
          userEmail = session.user.email;
          userName = session.user.name;
        }
        
        if (!userEmail) {
          console.log("❌ [INIT] Cannot auto-create creator without user email");
          return NextResponse.json(
            { 
              error: "Missing required field for creator profile creation",
              details: {
                message: "To auto-create a creator profile, the request must include user_email",
                required_fields: ["user_id", "user_email"],
                optional_fields: ["user_name"],
                received_fields: Object.keys(validatedData).filter(key => validatedData[key] !== undefined),
                example_request: {
                  user_id: "your_user_id_here",
                  user_email: "user@example.com",
                  user_name: "Optional Name"
                }
              }
            },
            { status: 400 }
          );
        }

        // Create new creator profile
        const creatorName = generateCreatorName(userEmail, userName);
        const newCreator = await db
          .insert(creators)
          .values({
            userId: validatedData.user_id,
            name: creatorName,
            email: userEmail,
          })
          .returning();

        creatorId = newCreator[0].id;
        console.log("✅ [INIT] Auto-created creator profile:", { creatorId, userId: validatedData.user_id, name: creatorName, email: userEmail });
      }
    } else if (creatorId) {
      // Legacy: lookup by creator_id
      console.log("🔍 [INIT] Looking up creator by creator_id (legacy):", creatorId);
      creator = await db
        .select()
        .from(creators)
        .where(eq(creators.id, creatorId))
        .limit(1);
        
      if (creator.length === 0) {
        console.log("❌ [INIT] Creator not found by creator_id:", creatorId);
        return NextResponse.json(
          { error: "Creator not found" },
          { status: 404 }
        );
      }
    } else {
      // Fallback: get first available creator (for backward compatibility)
      console.log("🔍 [INIT] No user_id or creator_id provided, getting first available creator");
      creator = await db
        .select()
        .from(creators)
        .limit(1);
      
      if (creator.length > 0) {
        creatorId = creator[0].id;
        console.log("✅ [INIT] Using fallback creator:", creatorId);
      } else {
        console.log("❌ [INIT] No creators available");
        return NextResponse.json(
          { error: "No creators available" },
          { status: 404 }
        );
      }
    }

    // Create new chat session
    const chatSession = await db
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

    const createdSession = chatSession[0];

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
          details: {
            message: "The request body contains invalid or missing fields",
            validation_errors: error.errors,
            expected_schema: {
              user_id: "string (required for auto-creator creation)",
              user_email: "string (required for auto-creator creation)", 
              user_name: "string (optional)",
              creator_id: "string (legacy, UUID format)",
              session_id: "string (optional)",
              visitor_uuid: "string (optional)",
              ad_preferences: "object (optional)",
              context: "string (optional)",
              metadata: "object (optional)"
            },
            example_request: {
              user_id: "wbxHQnUV3xlo2AeTDnryKar0NZ6zPX9C",
              user_email: "user@example.com",
              user_name: "John Doe"
            }
          }
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
    const sessionQuery = await db
      .select()
      .from(chatSessions)
      .where(eq(chatSessions.id, sessionId))
      .limit(1);

    if (sessionQuery.length === 0) {
      return NextResponse.json(
        { error: "Session not found" },
        { status: 404 }
      );
    }

    const sessionData = sessionQuery[0];

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