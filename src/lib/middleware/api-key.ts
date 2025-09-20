import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { apiKeys } from "@/lib/db/schema";
import { eq, and, isNull, sql } from "drizzle-orm";
import { z } from "zod";
import { AuthenticationError, AuthorizationError, RateLimitError } from "@/lib/api/errors";
import { errorResponse } from "@/lib/api/response";

import { logApiKeyValidation, logError } from "@/lib/logging/logger";
import crypto from "crypto";

// API Key validation result type
export interface ApiKeyValidation {
  valid: boolean;
  apiKey?: {
    id: string;
    userId: string;
    name: string | null;
    rateLimitEnabled: boolean;
    rateLimitMax: number;
    rateLimitTimeWindow: number;
    requestCount: number;
    remaining: number | null;
    permissions: any;
    metadata: any;
    rateLimit: any;
  };
  error?: string;
  remainingRequests?: number;
  resetTime?: number;
}

// Error classes
export class ApiKeyError extends Error {
  constructor(message: string, public statusCode: number = 401) {
    super(message);
    this.name = 'ApiKeyError';
  }
}

// Extract API key from request headers
function extractApiKey(request: NextRequest): string | null {
  // Check Authorization header (Bearer token)
  const authHeader = request.headers.get('authorization');
  if (authHeader?.startsWith('Bearer ')) {
    return authHeader.slice(7);
  }
  
  // Check X-API-Key header
  const apiKeyHeader = request.headers.get('x-api-key');
  if (apiKeyHeader) {
    return apiKeyHeader;
  }
  
  return null;
}

// Validate API key and check rate limits
export async function validateApiKey(request: NextRequest): Promise<ApiKeyValidation> {
  const requestId = crypto.randomBytes(8).toString('hex');
  const endpoint = new URL(request.url).pathname;
  const ipAddress = request.headers.get('x-forwarded-for') || request.headers.get('x-real-ip') || 'unknown';
  const userAgent = request.headers.get('user-agent') || 'unknown';
  
  try {
    // Debug all headers first
    const allHeaders: Record<string, string> = {};
    request.headers.forEach((value, key) => {
      allHeaders[key] = key.toLowerCase().includes('auth') || key.toLowerCase().includes('key') ? 
        `${value.substring(0, 10)}...` : value;
    });
    
    const apiKeyValue = extractApiKey(request);
    
    logApiKeyValidation({
      endpoint,
      requestId,
      success: false,
      reason: `API Key extraction: ${apiKeyValue ? 'Found' : 'Not found'} | Headers: ${JSON.stringify(allHeaders)}`,
      ipAddress,
    });
    
    if (!apiKeyValue) {
      logApiKeyValidation({
        endpoint,
        requestId,
        success: false,
        reason: 'No API key provided in Authorization (Bearer) or X-API-Key headers',
        ipAddress,
      });
      throw AuthenticationError.apiKeyRequired();
    }

    // Skip Better Auth for now and go straight to database validation
    logApiKeyValidation({
      endpoint,
      requestId,
      success: false,
      reason: `Skipping Better Auth validation for now, going straight to database lookup for key: ${apiKeyValue.substring(0, 15)}...`,
      ipAddress,
    });

    // Fallback to direct database query for backward compatibility
    logApiKeyValidation({
      endpoint,
      requestId,
      success: false,
      reason: `Falling back to database query for key: ${apiKeyValue.substring(0, 15)}...`,
      ipAddress,
    });

    const apiKeyResults = await db
      .select({
        id: apiKeys.id,
        userId: apiKeys.userId,
        name: apiKeys.name,
        key: apiKeys.key,
        permissions: apiKeys.permissions,
        metadata: apiKeys.metadata,
        rateLimit: apiKeys.rateLimit,
        lastUsedAt: apiKeys.lastUsedAt,
        createdAt: apiKeys.createdAt,
        updatedAt: apiKeys.updatedAt,
      })
      .from(apiKeys)
      .where(eq(apiKeys.key, apiKeyValue))
      .limit(1);

    // Also check if any keys exist with this value
    const allKeysWithValue = await db
      .select({
        id: apiKeys.id,
        metadata: apiKeys.metadata,
      })
      .from(apiKeys)
      .where(eq(apiKeys.key, apiKeyValue))
      .limit(5);

    if (apiKeyResults.length === 0) {
      logApiKeyValidation({
        endpoint,
        requestId,
        success: false,
        reason: `Database query result: No valid keys found. All key matches: ${JSON.stringify(allKeysWithValue.map(k => ({
          id: k.id,
          metadata: k.metadata
        })))}`,
        ipAddress,
      });
      
      return {
        valid: false,
        error: "Invalid or disabled API key"
      };
    }

    const apiKeyData = apiKeyResults[0];

    // Parse rate limit settings from JSON
    const rateLimit = (apiKeyData.rateLimit as any) || {};
    const rateLimitEnabled = rateLimit.enabled || false;
    const rateLimitMax = rateLimit.max || 100;
    const rateLimitTimeWindow = rateLimit.timeWindow || 86400000; // 24 hours

    // Check rate limits if enabled
    if (rateLimitEnabled) {
      const now = new Date();
      const timeWindow = rateLimitTimeWindow;
      const maxRequests = rateLimitMax;
      
      // Calculate time window start
      const windowStart = new Date(now.getTime() - timeWindow);
      
      // If last request was outside the current window, reset counter
      const shouldResetCounter = !apiKeyData.lastUsedAt ||
        apiKeyData.lastUsedAt < windowStart;

      // Get current request count from metadata
      const metadata = (apiKeyData.metadata as any) || {};
      let currentCount = shouldResetCounter ? 0 : (metadata.requestCount || 0);
      
      if (currentCount >= maxRequests) {
        const resetTime = apiKeyData.lastUsedAt
          ? new Date(apiKeyData.lastUsedAt.getTime() + timeWindow).getTime()
          : now.getTime() + timeWindow;
        
        logApiKeyValidation({
          endpoint,
          requestId,
          success: false,
          reason: `Rate limit exceeded: ${currentCount}/${maxRequests}`,
          userId: apiKeyData.userId,
          ipAddress,
        });
          
        return {
          valid: false,
          error: "Rate limit exceeded",
          remainingRequests: 0,
          resetTime: resetTime
        };
      }

      // Update request count and last request time
      const updatedMetadata = {
        ...metadata,
        requestCount: currentCount + 1,
        remaining: maxRequests - (currentCount + 1)
      };

      await db
        .update(apiKeys)
        .set({
          metadata: updatedMetadata,
          lastUsedAt: now
        })
        .where(eq(apiKeys.id, apiKeyData.id));

      logApiKeyValidation({
        endpoint,
        requestId,
        success: true,
        userId: apiKeyData.userId,
        ipAddress,
      });

      return {
        valid: true,
        apiKey: {
          id: apiKeyData.id,
          userId: apiKeyData.userId,
          name: apiKeyData.name,
          rateLimitEnabled: true,
          rateLimitMax: maxRequests,
          rateLimitTimeWindow: timeWindow,
          requestCount: currentCount + 1,
          remaining: maxRequests - (currentCount + 1),
          permissions: apiKeyData.permissions,
          metadata: apiKeyData.metadata,
          rateLimit: apiKeyData.rateLimit,
        },
        remainingRequests: maxRequests - (currentCount + 1)
      };
    }

    // No rate limiting - just track the request
    const metadata = (apiKeyData.metadata as any) || {};
    const updatedMetadata = {
      ...metadata,
      requestCount: (metadata.requestCount || 0) + 1
    };

    await db
      .update(apiKeys)
      .set({
        metadata: updatedMetadata,
        lastUsedAt: new Date()
      })
      .where(eq(apiKeys.id, apiKeyData.id));

    logApiKeyValidation({
      endpoint,
      requestId,
      success: true,
      userId: apiKeyData.userId,
      ipAddress,
    });

    return {
      valid: true,
      apiKey: {
        id: apiKeyData.id,
        userId: apiKeyData.userId,
        name: apiKeyData.name,
        rateLimitEnabled: false,
        rateLimitMax: 0,
        rateLimitTimeWindow: 0,
        requestCount: (metadata.requestCount || 0) + 1,
        remaining: null,
        permissions: apiKeyData.permissions,
        metadata: apiKeyData.metadata,
        rateLimit: apiKeyData.rateLimit,
      }
    };

  } catch (error) {
    logError({
      endpoint,
      requestId,
      error: error instanceof Error ? error : String(error),
    });
    
    return {
      valid: false,
      error: "Internal server error during API key validation"
    };
  }
}

// Middleware wrapper for Next.js API routes
export function withApiKey(handler: (request: NextRequest, validation: ApiKeyValidation) => Promise<NextResponse>) {
  return async (request: NextRequest) => {
    const validation = await validateApiKey(request);
    
    if (!validation.valid) {
      // Handle different error types with appropriate responses using centralized error system
      if (validation.error === "API key required") {
        return errorResponse(AuthenticationError.apiKeyRequired());
      } else if (validation.error === "API key has expired") {
        return errorResponse(AuthenticationError.apiKeyExpired());
      } else if (validation.error === "Rate limit exceeded") {
        return errorResponse(RateLimitError.exceeded(
          validation.apiKey?.rateLimitMax || 10,
          validation.apiKey?.rateLimitTimeWindow || 86400000,
          validation.resetTime,
          validation.remainingRequests || 0
        ));
      } else {
        return errorResponse(AuthenticationError.apiKeyInvalid());
      }
    }

    // Execute the handler
    const response = await handler(request, validation);
    
    // Add rate limit headers to successful responses
    return addRateLimitHeaders(response, {
      limit: validation.apiKey?.rateLimitMax,
      remaining: validation.remainingRequests,
      resetTime: validation.resetTime
    });
  };
}

// Helper to check if user owns the resource
export function checkResourceAccess(validation: ApiKeyValidation, resourceUserId: string): boolean {
  return validation.apiKey?.userId === resourceUserId;
}

// Permission-based access control
export function hasPermission(validation: ApiKeyValidation, permission: string): boolean {
  if (!validation.apiKey?.permissions) {
    return true; // No permissions set = full access
  }
  
  try {
    const permissions = JSON.parse(validation.apiKey.permissions);
    return permissions.includes(permission) || permissions.includes('*');
  } catch {
    return true; // Invalid permissions JSON = full access
  }
}

// Add rate limit headers to responses
function addRateLimitHeaders(response: NextResponse, rateLimitInfo: {
  limit?: number;
  remaining?: number;
  resetTime?: number;
}): NextResponse {
  if (rateLimitInfo.limit !== undefined) {
    response.headers.set('X-RateLimit-Limit', rateLimitInfo.limit.toString());
  }
  
  if (rateLimitInfo.remaining !== undefined) {
    response.headers.set('X-RateLimit-Remaining', rateLimitInfo.remaining.toString());
  }
  
  if (rateLimitInfo.resetTime !== undefined) {
    response.headers.set('X-RateLimit-Reset', Math.ceil(rateLimitInfo.resetTime / 1000).toString());
  }
  
  return response;
}