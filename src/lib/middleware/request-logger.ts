import { NextRequest, NextResponse } from "next/server";
import { logApiRequest, logApiResponse, logError } from "@/lib/logging/logger";
import crypto from "crypto";

export interface RequestContext {
  requestId: string;
  startTime: number;
  endpoint: string;
  method: string;
  userId?: string;
  ipAddress?: string;
  userAgent?: string;
}

export function withRequestLogging<T extends any[]>(
  handler: (request: NextRequest, ...args: T) => Promise<NextResponse>
) {
  return async (request: NextRequest, ...args: T): Promise<NextResponse> => {
    const startTime = Date.now();
    const requestId = crypto.randomBytes(8).toString('hex');
    const endpoint = new URL(request.url).pathname;
    const method = request.method;
    const ipAddress = request.headers.get('x-forwarded-for') || request.headers.get('x-real-ip') || 'unknown';
    const userAgent = request.headers.get('user-agent') || 'unknown';

    const context: RequestContext = {
      requestId,
      startTime,
      endpoint,
      method,
      ipAddress,
      userAgent,
    };

    // Log incoming request with comprehensive details
    logApiRequest({
      endpoint,
      method,
      requestId,
      ipAddress,
      userAgent,
    });

    // Log request details for debugging
    const requestDetails = {
      url: request.url,
      method: request.method,
      hasBody: ['POST', 'PUT', 'PATCH'].includes(request.method),
      contentType: request.headers.get('content-type'),
      hasAuth: !!(request.headers.get('authorization') || request.headers.get('x-api-key')),
      headersCount: Array.from(request.headers.keys()).length,
    };

    logApiRequest({
      endpoint: endpoint + '/details',
      method: 'DEBUG',
      requestId,
      ipAddress,
      userAgent: JSON.stringify(requestDetails),
    });

    try {
      // Execute the handler
      const response = await handler(request, ...args);
      
      // Log successful response
      const duration = Date.now() - startTime;
      const statusCode = response.status;
      
      logApiResponse({
        endpoint,
        method,
        requestId,
        statusCode,
        duration,
      });

      // Add request ID to response headers for tracing
      response.headers.set('X-Request-ID', requestId);
      
      return response;
    } catch (error) {
      const duration = Date.now() - startTime;
      
      // Log error
      logError({
        endpoint,
        requestId,
        error: error instanceof Error ? error : String(error),
      });

      // Log error response
      logApiResponse({
        endpoint,
        method,
        requestId,
        statusCode: 500,
        duration,
      });

      // Re-throw to let error handling middleware deal with it
      throw error;
    }
  };
}