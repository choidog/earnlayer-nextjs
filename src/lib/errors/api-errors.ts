import { NextResponse } from "next/server";

// Standard API error codes
export const API_ERROR_CODES = {
  INVALID_API_KEY: 'INVALID_API_KEY',
  API_KEY_REQUIRED: 'API_KEY_REQUIRED',
  API_KEY_EXPIRED: 'API_KEY_EXPIRED',
  RATE_LIMIT_EXCEEDED: 'RATE_LIMIT_EXCEEDED',
  INSUFFICIENT_PERMISSIONS: 'INSUFFICIENT_PERMISSIONS',
  ACCESS_DENIED: 'ACCESS_DENIED',
  VALIDATION_ERROR: 'VALIDATION_ERROR',
  INTERNAL_ERROR: 'INTERNAL_ERROR'
} as const;

export type ApiErrorCode = typeof API_ERROR_CODES[keyof typeof API_ERROR_CODES];

export interface ApiErrorResponse {
  error: string;
  code: ApiErrorCode;
  details?: any;
  timestamp?: string;
}

// API error response builder
export function createApiErrorResponse(
  message: string, 
  code: ApiErrorCode, 
  status: number = 400,
  details?: any
): NextResponse {
  const errorResponse: ApiErrorResponse = {
    error: message,
    code,
    timestamp: new Date().toISOString()
  };

  if (details) {
    errorResponse.details = details;
  }

  return NextResponse.json(errorResponse, { status });
}

// Common API error responses
export const ApiErrors = {
  invalidApiKey: () => createApiErrorResponse(
    "Invalid or disabled API key", 
    API_ERROR_CODES.INVALID_API_KEY, 
    401
  ),

  apiKeyRequired: () => createApiErrorResponse(
    "API key required. Provide in Authorization header as 'Bearer <key>' or X-API-Key header.", 
    API_ERROR_CODES.API_KEY_REQUIRED, 
    401
  ),

  apiKeyExpired: () => createApiErrorResponse(
    "API key has expired", 
    API_ERROR_CODES.API_KEY_EXPIRED, 
    401
  ),

  rateLimitExceeded: (resetTime?: number) => {
    const response = createApiErrorResponse(
      "Rate limit exceeded. Please wait before making more requests.", 
      API_ERROR_CODES.RATE_LIMIT_EXCEEDED, 
      429
    );
    
    if (resetTime) {
      response.headers.set('X-RateLimit-Reset', Math.ceil(resetTime / 1000).toString());
    }
    
    return response;
  },

  insufficientPermissions: (permission?: string) => createApiErrorResponse(
    `Insufficient permissions${permission ? ` for ${permission}` : ''}`, 
    API_ERROR_CODES.INSUFFICIENT_PERMISSIONS, 
    403
  ),

  accessDenied: (resource?: string) => createApiErrorResponse(
    `Access denied${resource ? ` to ${resource}` : ''}`, 
    API_ERROR_CODES.ACCESS_DENIED, 
    403
  ),

  validationError: (details: any) => createApiErrorResponse(
    "Request validation failed", 
    API_ERROR_CODES.VALIDATION_ERROR, 
    400,
    details
  ),

  internalError: () => createApiErrorResponse(
    "Internal server error", 
    API_ERROR_CODES.INTERNAL_ERROR, 
    500
  )
};

// Rate limit headers helper
export function addRateLimitHeaders(response: NextResponse, rateLimitInfo: {
  limit?: number;
  remaining?: number;
  resetTime?: number;
}) {
  if (rateLimitInfo.limit) {
    response.headers.set('X-RateLimit-Limit', rateLimitInfo.limit.toString());
  }
  
  if (rateLimitInfo.remaining !== undefined) {
    response.headers.set('X-RateLimit-Remaining', rateLimitInfo.remaining.toString());
  }
  
  if (rateLimitInfo.resetTime) {
    response.headers.set('X-RateLimit-Reset', Math.ceil(rateLimitInfo.resetTime / 1000).toString());
  }
  
  return response;
}

// Successful response with rate limit headers
export function createSuccessResponse(data: any, rateLimitInfo?: {
  limit?: number;
  remaining?: number;
  resetTime?: number;
}): NextResponse {
  const response = NextResponse.json(data);
  
  if (rateLimitInfo) {
    addRateLimitHeaders(response, rateLimitInfo);
  }
  
  return response;
}