import { NextRequest, NextResponse } from "next/server";
import { validateApiKey } from "@/lib/middleware/api-key";
import { logApiKeyValidation } from "@/lib/logging/logger";
import crypto from "crypto";

export async function POST(request: NextRequest) {
  const requestId = crypto.randomBytes(8).toString('hex');
  const endpoint = '/api/debug/test-api-key';
  
  try {
    // Get the request body to test with
    const body = await request.json();
    const testApiKey = body.apiKey;
    
    if (!testApiKey) {
      return NextResponse.json({
        success: false,
        error: "Please provide an apiKey in the request body",
        requestId,
      }, { status: 400 });
    }

    // Create a mock request with the API key
    const mockHeaders = new Headers();
    mockHeaders.set('authorization', `Bearer ${testApiKey}`);
    mockHeaders.set('content-type', 'application/json');
    
    const mockRequest = new NextRequest('https://example.com/api/test', {
      method: 'POST',
      headers: mockHeaders,
    });

    logApiKeyValidation({
      endpoint,
      requestId,
      success: false,
      reason: `Testing API key: ${testApiKey.substring(0, 15)}...`,
      ipAddress: request.headers.get('x-forwarded-for') || 'unknown',
    });

    // Test the API key validation
    const validation = await validateApiKey(mockRequest);

    return NextResponse.json({
      success: true,
      requestId,
      testResult: {
        valid: validation.valid,
        error: validation.error,
        apiKey: validation.apiKey ? {
          id: validation.apiKey.id,
          userId: validation.apiKey.userId,
          name: validation.apiKey.name,
          rateLimitEnabled: validation.apiKey.rateLimitEnabled,
          requestCount: validation.apiKey.requestCount,
          remaining: validation.apiKey.remaining,
        } : null,
        remainingRequests: validation.remainingRequests,
        resetTime: validation.resetTime,
      },
      debugInfo: {
        providedKey: `${testApiKey.substring(0, 15)}...`,
        keyLength: testApiKey.length,
        timestamp: new Date().toISOString(),
      }
    });

  } catch (error) {
    console.error('Error testing API key:', error);
    return NextResponse.json({
      success: false,
      error: 'Failed to test API key',
      details: error instanceof Error ? error.message : 'Unknown error',
      requestId,
    }, { status: 500 });
  }
}

export async function GET(request: NextRequest) {
  return NextResponse.json({
    endpoint: '/api/debug/test-api-key',
    method: 'POST',
    description: 'Test API key validation',
    usage: {
      body: {
        apiKey: 'your-api-key-to-test'
      }
    },
    response: {
      success: 'boolean',
      testResult: {
        valid: 'boolean',
        error: 'string | undefined',
        apiKey: 'object | null',
      },
      debugInfo: 'object'
    }
  });
}