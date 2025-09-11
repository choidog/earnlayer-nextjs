import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { adClicks, adImpressions, creators } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { z } from "zod";
import { withApiKey, checkResourceAccess, type ApiKeyValidation } from "@/lib/middleware/api-key";
import { Logger } from "@/lib/logging/logger";
import { successResponse, errorResponse } from "@/lib/api/response";
import { NotFoundError, AuthorizationError, DatabaseError, ValidationError } from "@/lib/api/errors";

async function handleGet(
  request: NextRequest,
  validation: ApiKeyValidation,
  { params }: { params: Promise<{ impressionId: string }> }
): Promise<NextResponse> {
  const logger = Logger.fromRequest(request, { endpoint: 'ads/click' });
  
  try {
    const { impressionId } = await params;
    logger.requestStart({ impressionId });

    if (!impressionId) {
      const error = new ValidationError(
        "Impression ID is required",
        { required_parameter: "impressionId" },
        "MISSING_IMPRESSION_ID"
      );
      return errorResponse(error, logger.context.requestId);
    }

    // Validate that the impression exists and get creator info
    const impression = await db
      .select({
        id: adImpressions.id,
        creatorId: adImpressions.creatorId,
      })
      .from(adImpressions)
      .where(eq(adImpressions.id, impressionId))
      .limit(1);

    if (impression.length === 0) {
      const error = new NotFoundError(
        "Impression not found",
        { impression_id: impressionId },
        "IMPRESSION_NOT_FOUND"
      );
      logger.error("Impression lookup failed", error);
      return errorResponse(error, logger.context.requestId);
    }

    // Get creator's user ID to verify ownership
    const creatorResult = await db
      .select({ userId: creators.userId })
      .from(creators)
      .where(eq(creators.id, impression[0].creatorId))
      .limit(1);

    if (creatorResult.length === 0) {
      const error = new NotFoundError(
        "Creator not found for this impression",
        { creator_id: impression[0].creatorId, impression_id: impressionId },
        "CREATOR_NOT_FOUND"
      );
      logger.error("Creator lookup failed", error);
      return errorResponse(error, logger.context.requestId);
    }

    // Check if API key user can record clicks for this creator
    if (!checkResourceAccess(validation, creatorResult[0].userId)) {
      const error = AuthorizationError.resourceAccessDenied('click tracking', impressionId);
      logger.error("Resource access denied", error, {
        api_key_user: validation.apiKey?.userId,
        resource_owner: creatorResult[0].userId
      });
      return errorResponse(error, logger.context.requestId);
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

    logger.info('Click recorded successfully', {
      click_id: click[0].id,
      impression_id: impressionId,
      created_at: click[0].createdAt
    });

    return successResponse({
      click_id: click[0].id,
      impression_id: impressionId,
      recorded_at: click[0].createdAt,
      status: "success"
    }, { requestId: logger.context.requestId });

  } catch (error) {
    if (error instanceof NotFoundError || error instanceof AuthorizationError || error instanceof ValidationError) {
      return errorResponse(error, logger.context.requestId);
    }

    logger.error("Unexpected error recording click", error as Error);
    const dbError = new DatabaseError(
      "Failed to record click",
      { operation: "insert_click", impression_id: impressionId },
      "CLICK_INSERT_FAILED"
    );
    return errorResponse(dbError, logger.context.requestId);
  }
}

// Wrapper for withApiKey - handles the params properly
export function GET(
  request: NextRequest,
  context: { params: Promise<{ impressionId: string }> }
) {
  return withApiKey((req, validation) => handleGet(req, validation, context))(request);
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