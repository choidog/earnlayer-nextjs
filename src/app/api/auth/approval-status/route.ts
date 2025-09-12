import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { creators, user } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { auth } from "@/lib/auth/config";

// Handle preflight requests
export async function OPTIONS(request: NextRequest) {
  return new NextResponse(null, {
    status: 200,
    headers: {
      'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Allow-Credentials': 'true',
    },
  });
}

export async function GET(request: NextRequest) {
  try {
    // Get current user session
    const session = await auth.api.getSession({
      headers: request.headers
    });

    if (!session?.user?.id) {
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

    // Check if user has a creator profile and their approval status
    const creatorProfile = await db
      .select({
        approvalStatus: creators.approvalStatus,
        approvalDate: creators.approvalDate,
        rejectionReason: creators.rejectionReason,
        lastApprovalCheck: creators.lastApprovalCheck,
      })
      .from(creators)
      .where(eq(creators.userId, session.user.id))
      .limit(1);

    if (creatorProfile.length === 0) {
      // No creator profile exists - user is not approved
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
        message: getStatusMessage(profile.approvalStatus, profile.rejectionReason)
      }
    }, {
      headers: {
        'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
        'Access-Control-Allow-Credentials': 'true',
      }
    });

  } catch (error) {
    console.error("Error checking approval status:", error);
    return NextResponse.json(
      { error: "Failed to check approval status" },
      { 
        status: 500,
        headers: {
          'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
          'Access-Control-Allow-Credentials': 'true',
        }
      }
    );
  }
}

function getStatusMessage(status: string, rejectionReason?: string | null): string {
  switch (status) {
    case 'approved':
      return 'Your account has been approved and you have full access.';
    case 'rejected':
      return rejectionReason ? `Your account was rejected: ${rejectionReason}` : 'Your account was rejected.';
    case 'suspended':
      return 'Your account has been suspended. Please contact support.';
    case 'pending':
    default:
      return 'Your account is pending approval. You will be notified once approved.';
  }
}