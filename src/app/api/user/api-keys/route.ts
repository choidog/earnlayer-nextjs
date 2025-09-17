import { NextRequest, NextResponse } from "next/server";

import { db } from "@/lib/db/connection";
import { apikey, creators } from "@/lib/db/schema";
import { eq } from "drizzle-orm";

export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const checkApproval = searchParams.get('approval') === 'true';

    // Get the authenticated user
    const session = await 
      headers: request.headers,
    });

    if (!session?.user) {
      return NextResponse.json(
        { error: "Authentication required" },
        { 
          status: 401,
          headers: {
            'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
            'Access-Control-Allow-Credentials': 'true',
          }
        }
      );
    }

    // If checking approval status
    if (checkApproval) {
      const creatorProfile = await db
        .select({
          approvalStatus: creators.approvalStatus,
          approvalDate: creators.approvalDate,
          rejectionReason: creators.rejectionReason,
          lastApprovalCheck: creators.lastApprovalCheck,
        })
        .from(creators)
        .where(eq(creators.userId, userId))
        .limit(1);

      if (creatorProfile.length === 0) {
        return NextResponse.json({
          success: true,
          data: {
            isApproved: false,
            status: 'pending',
            hasCreatorProfile: false,
            message: 'No creator profile found. Your account is pending approval.'
          }
        }, {
          headers: {
            'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
            'Access-Control-Allow-Credentials': 'true',
          }
        });
      }

      const profile = creatorProfile[0];
      const isApproved = profile.approvalStatus === 'approved';

      return NextResponse.json({
        success: true,
        data: {
          isApproved,
          status: profile.approvalStatus,
          hasCreatorProfile: true,
          approvalDate: profile.approvalDate?.toISOString(),
          rejectionReason: profile.rejectionReason,
          lastApprovalCheck: profile.lastApprovalCheck?.toISOString(),
          message: getApprovalStatusMessage(profile.approvalStatus, profile.rejectionReason)
        }
      }, {
        headers: {
          'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
          'Access-Control-Allow-Credentials': 'true',
        }
      });
    }

    // Fetch user's API keys directly from database
    const userApiKeys = await db
      .select({
        id: apikey.id,
        name: apikey.name,
        key: apikey.key, // Get the actual key value
        enabled: apikey.enabled,
        rateLimitEnabled: apikey.rateLimitEnabled,
        rateLimitMax: apikey.rateLimitMax,
        rateLimitTimeWindow: apikey.rateLimitTimeWindow,
        requestCount: apikey.requestCount,
        remaining: apikey.remaining,
        lastRequest: apikey.lastRequest,
        expiresAt: apikey.expiresAt,
        createdAt: apikey.createdAt,
      })
      .from(apikey)
      .where(eq(apikey.userId, userId))
      .orderBy(apikey.createdAt);

    // Format response with actual key values
    const formattedKeys = userApiKeys.map(key => ({
      id: key.id,
      name: key.name || 'Unnamed Key',
      key: key.key, // Return the full key value
      enabled: key.enabled,
      rateLimitEnabled: key.rateLimitEnabled,
      rateLimitMax: key.rateLimitMax,
      rateLimitTimeWindow: key.rateLimitTimeWindow,
      requestCount: key.requestCount || 0,
      remaining: key.remaining,
      lastRequest: key.lastRequest,
      expiresAt: key.expiresAt,
      createdAt: key.createdAt,
    }));

    return NextResponse.json({
      success: true,
      keys: formattedKeys,
      count: formattedKeys.length,
    });

  } catch (error) {
    console.error("Error fetching user API keys:", error);
    return NextResponse.json(
      { 
        error: "Failed to fetch API keys",
        details: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    );
  }
}

// Optional: Create new API key endpoint  
export async function POST(request: NextRequest) {
  try {
    const session = await 
      headers: request.headers,
    });

    if (!session?.user) {
      return NextResponse.json(
        { error: "Authentication required" },
        { status: 401 }
      );
    }

    const body = await request.json();
    const { name } = body;

    // Create new API key using Better Auth
    const newApiKey = await auth.api.createApiKey({
      userId: userId,
      name: name || 'New API Key',
      expiresIn: 30 * 24 * 60 * 60 * 1000, // 30 days
    });

    return NextResponse.json({
      success: true,
      key: {
        id: newApiKey.keyId,
        name: name || 'New API Key',
        key: newApiKey.key, // Return the new key value
        enabled: true,
        createdAt: new Date().toISOString(),
      }
    });

  } catch (error) {
    console.error("Error creating API key:", error);
    return NextResponse.json(
      { 
        error: "Failed to create API key",
        details: error instanceof Error ? error.message : 'Unknown error'
      },
      { status: 500 }
    );
  }
}
function getApprovalStatusMessage(status: string, rejectionReason?: string | null): string {
  switch (status) {
    case "approved":
      return "Your account has been approved and you have full access.";
    case "rejected":
      return rejectionReason ? `Your account was rejected: ${rejectionReason}` : "Your account was rejected.";
    case "suspended":
      return "Your account has been suspended. Please contact support.";
    case "pending":
    default:
      return "Your account is pending approval. You will be notified once approved.";
  }
}
