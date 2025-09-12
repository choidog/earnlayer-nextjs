import { NextRequest, NextResponse } from "next/server";
import { agreementService } from "@/services/AgreementService";

export async function GET(request: NextRequest) {
  try {
    const currentVersion = await agreementService.getCurrentVersion();

    return NextResponse.json({
      success: true,
      data: {
        id: currentVersion.id,
        version: currentVersion.versionString,
        contentHash: currentVersion.contentHash,
        content: currentVersion.contentText,
        effectiveDate: currentVersion.effectiveDate.toISOString(),
      }
    }, {
      headers: {
        'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
        'Access-Control-Allow-Credentials': 'true',
      }
    });
  } catch (error) {
    console.error("Error fetching current agreement:", error);
    return NextResponse.json(
      { error: "Failed to fetch current agreement" },
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