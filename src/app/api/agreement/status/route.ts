import { NextRequest, NextResponse } from "next/server";

import { agreementService } from "@/services/AgreementService";

export async function GET(request: NextRequest) {
  try {
    // Get authenticated user
    const { searchParams } = new URL(request.url);
    const userId = searchParams.get("userId");

    if (!userId) {
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

    const status = await agreementService.getUserAgreementStatus(userId);

    return NextResponse.json({
      success: true,
      data: {
        hasAcceptedCurrent: status.hasAcceptedCurrent,
        needsUpdate: status.needsUpdate,
        currentVersion: {
          id: status.latestVersion.id,
          version: status.latestVersion.versionString,
          effectiveDate: status.latestVersion.effectiveDate.toISOString(),
        },
        acceptedVersion: status.currentVersionAccepted ? {
          id: status.currentVersionAccepted.id,
          version: status.currentVersionAccepted.versionString,
          acceptedAt: status.acceptedAt?.toISOString(),
        } : null,
      }
    }, {
      headers: {
        'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
        'Access-Control-Allow-Credentials': 'true',
      }
    });

  } catch (error) {
    console.error("Error fetching agreement status:", error);
    return NextResponse.json(
      { error: "Failed to fetch agreement status" },
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