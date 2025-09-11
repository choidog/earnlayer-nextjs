import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { adImpressions, creators } from "@/lib/db/schema";
import { z } from "zod";
import { withApiKey, checkResourceAccess, type ApiKeyValidation } from "@/lib/middleware/api-key";
import { eq } from "drizzle-orm";
import { Logger } from "@/lib/logging/logger";
import { successResponse, errorResponse, validationErrorWithSchema } from "@/lib/api/response";
import { NotFoundError, AuthorizationError, DatabaseError } from "@/lib/api/errors";

const impressionRequestSchema = z.object({
  ad_id: z.string().uuid(),
  conversation_id: z.string().uuid(),
  creator_id: z.string().uuid(), // Required for user isolation
  impression_id: z.string(),
  ad_type: z.string(),
  placement: z.string(),
  similarity: z.number().optional(),
  context: z.string().optional(),
  metadata: z.record(z.any()).optional(),
});

async function handlePost(request: NextRequest, validation: ApiKeyValidation): Promise<NextResponse> {
  const logger = Logger.fromRequest(request, { endpoint: 'ads/impressions' });
  
  try {
    const body = await request.json();
    logger.requestStart(body);
    
    const validatedData = impressionRequestSchema.parse(body);

    // Get creator's user ID to verify ownership
    const creatorResult = await db
      .select({ userId: creators.userId })
      .from(creators)
      .where(eq(creators.id, validatedData.creator_id))
      .limit(1);

    if (creatorResult.length === 0) {
      const error = new NotFoundError(
        "Creator not found",
        { creator_id: validatedData.creator_id },
        "CREATOR_NOT_FOUND"
      );
      logger.error("Creator lookup failed", error);
      return errorResponse(error, logger.context.requestId);
    }

    // Check if API key user can record impressions for this creator
    if (!checkResourceAccess(validation, creatorResult[0].userId)) {
      const error = AuthorizationError.resourceAccessDenied('creator impressions', validatedData.creator_id);
      logger.error("Resource access denied", error, {
        api_key_user: validation.apiKey?.userId,
        resource_owner: creatorResult[0].userId
      });
      return errorResponse(error, logger.context.requestId);
    }

    // Record the impression in the database
    const impression = await db
      .insert(adImpressions)
      .values({
        // id will be auto-generated as UUID
        adId: validatedData.ad_id,
        creatorId: validatedData.creator_id, // Now required for user isolation
        sessionId: validatedData.conversation_id,
        impressionType: validatedData.ad_type,
        adQueuePlacement: validatedData.placement,
        revenueAmount: "0", // Default for now
        creatorPayoutAmount: "0", // Default for now
        // Other fields will use defaults
      })
      .returning();

    logger.info('Impression recorded successfully', {
      impression_id: impression[0].id,
      ad_id: validatedData.ad_id,
      conversation_id: validatedData.conversation_id
    });

    return successResponse({
      impression_id: impression[0].id,
      recorded_at: impression[0].createdAt,
      status: "success"
    }, { requestId: logger.context.requestId });

  } catch (error) {
    if (error instanceof z.ZodError) {
      const validationError = validationErrorWithSchema(error, impressionRequestSchema, logger);
      return errorResponse(validationError, logger.context.requestId);
    }

    if (error instanceof NotFoundError || error instanceof AuthorizationError) {
      return errorResponse(error, logger.context.requestId);
    }

    logger.error("Unexpected error recording impression", error as Error);
    const dbError = new DatabaseError(
      "Failed to record impression",
      { operation: "insert_impression" },
      "IMPRESSION_INSERT_FAILED"
    );
    return errorResponse(dbError, logger.context.requestId);
  }
}

export const POST = withApiKey(handlePost);

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