import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { chatSessions, creators } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";

import crypto from "crypto";
import { Logger } from "@/lib/logging/logger";
import { successResponse, errorResponse, validationErrorWithSchema } from "@/lib/api/response";
import { ValidationError, BusinessLogicError, NotFoundError } from "@/lib/api/errors";

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
  const logger = Logger.fromRequest(request, { endpoint: 'conversations/initialize' });
  
  try {
    logger.info("Starting conversation initialization");
    
    const body = await request.json();
    logger.requestStart(body);
    
    const validatedData = initializeRequestSchema.parse(body);

    // Get Better Auth session for auto-creator creation (optional fallback)
    let session = null;
    try {
      session = await 
        headers: request.headers,
      });
      if (session?.user) {
        logger.setContext({ userId: userId, userEmail: session.user.email });
      }
    } catch (error) {
      logger.warn("No authenticated session found");
    }

    // Get creator (support both user_id and legacy creator_id with auto-creation)
    let creatorId = validatedData.creator_id;
    let creator;

    if (validatedData.user_id) {
      // Preferred: lookup by user_id with auto-creation
      logger.info("Looking up creator by user_id", { user_id: validatedData.user_id });
      creator = await db
        .select()
        .from(creators)
        .where(eq(creators.userId, validatedData.user_id))
        .limit(1);
        
      if (creator.length > 0) {
        creatorId = creator[0].id;
        logger.info("Found existing creator", { creatorId, userId: validatedData.user_id });
      } else {
        // Auto-create creator profile
        logger.info("Auto-creating creator profile", { user_id: validatedData.user_id });
        
        // Use provided user data or fall back to session data
        let userEmail = validatedData.user_email;
        let userName = validatedData.user_name;
        
        if (!userEmail && session) {
          userEmail = session.user.email;
          userName = session.user.name;
        }
        
        if (!userEmail) {
          const error = new BusinessLogicError(
            "Cannot auto-create creator profile without user email",
            {
              message: "To auto-create a creator profile, the request must include user_email",
              required_fields: ["user_id", "user_email"],
              optional_fields: ["user_name"],
              received_fields: Object.keys(validatedData).filter(key => validatedData[key] !== undefined),
              example_request: {
                user_id: "your_user_id_here",
                user_email: "user@example.com",
                user_name: "Optional Name"
              }
            },
            "CREATOR_AUTO_CREATION_MISSING_EMAIL"
          );
          logger.error("Creator auto-creation failed", error, { received_fields: Object.keys(validatedData) });
          return errorResponse(error, logger.context.requestId);
        }

        // Create new creator profile
        const creatorName = generateCreatorName(userEmail, userName);
        try {
          const newCreator = await db
            .insert(creators)
            .values({
              userId: validatedData.user_id,
              name: creatorName,
              email: userEmail,
            })
            .returning();

          creatorId = newCreator[0].id;
          logger.info("Auto-created creator profile", { 
            creatorId, 
            userId: validatedData.user_id, 
            name: creatorName, 
            email: userEmail 
          });
        } catch (dbError) {
          logger.databaseError("creator creation", dbError as Error);
          throw new BusinessLogicError(
            "Failed to create creator profile",
            { user_id: validatedData.user_id, email: userEmail },
            "CREATOR_CREATION_FAILED"
          );
        }
      }
    } else if (creatorId) {
      // Legacy: lookup by creator_id
      logger.info("Looking up creator by creator_id (legacy)", { creator_id: creatorId });
      creator = await db
        .select()
        .from(creators)
        .where(eq(creators.id, creatorId))
        .limit(1);
        
      if (creator.length === 0) {
        const error = new NotFoundError(
          "Creator not found",
          { creator_id: creatorId },
          "CREATOR_NOT_FOUND"
        );
        logger.error("Creator lookup failed", error);
        return errorResponse(error, logger.context.requestId);
      }
    } else {
      // Fallback: get first available creator (for backward compatibility)
      logger.info("No user_id or creator_id provided, using fallback creator");
      creator = await db
        .select()
        .from(creators)
        .limit(1);
      
      if (creator.length > 0) {
        creatorId = creator[0].id;
        logger.info("Using fallback creator", { creatorId });
      } else {
        const error = new NotFoundError(
          "No creators available",
          { message: "No creator profiles exist in the system" },
          "NO_CREATORS_AVAILABLE"
        );
        logger.error("No creators available for fallback", error);
        return errorResponse(error, logger.context.requestId);
      }
    }

    // Create new chat session
    try {
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
      logger.info("Created chat session", { sessionId: createdSession.id, creatorId });

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

      const responseData = {
        conversation_id: createdSession.id,
        creator_id: creatorId,
        ad_settings: adSettings,
        status: "initialized",
        created_at: createdSession.startedAt.toISOString(),
      };

      logger.info("Conversation initialization completed successfully", { 
        conversationId: createdSession.id 
      });

      return successResponse(responseData, { requestId: logger.context.requestId });
    } catch (dbError) {
      logger.databaseError("chat session creation", dbError as Error);
      throw new BusinessLogicError(
        "Failed to create chat session",
        { creatorId },
        "CHAT_SESSION_CREATION_FAILED"
      );
    }

  } catch (error) {
    if (error instanceof z.ZodError) {
      const validationError = validationErrorWithSchema(error, initializeRequestSchema, logger);
      return errorResponse(validationError, logger.context.requestId);
    }

    if (error instanceof ValidationError || error instanceof BusinessLogicError || error instanceof NotFoundError) {
      return errorResponse(error, logger.context.requestId);
    }

    logger.error("Unexpected error in conversation initialization", error as Error);
    return errorResponse(error as Error, logger.context.requestId);
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