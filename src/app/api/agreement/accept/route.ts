import { NextRequest, NextResponse } from "next/server";

import { agreementService } from "@/services/AgreementService";
import { z } from "zod";

const acceptSchema = z.object({
  versionId: z.string(),
  acceptanceMethod: z.string().optional().default("clickwrap"),
});

export async function POST(request: NextRequest) {
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

    const body = await request.json();
    const { versionId, acceptanceMethod } = acceptSchema.parse(body);

    // Extract metadata
    const ipAddress = request.headers.get('x-forwarded-for') || request.headers.get('x-real-ip') || undefined;
    const userAgent = request.headers.get('user-agent') || undefined;

    // Record acceptance
    await agreementService.acceptAgreement(userId, versionId, {
      ipAddress,
      userAgent,
      acceptanceMethod,
    });

    return NextResponse.json({
      success: true,
      message: "Agreement accepted successfully",
      acceptedAt: new Date().toISOString(),
    }, {
      headers: {
        'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
        'Access-Control-Allow-Credentials': 'true',
      }
    });

  } catch (error) {
    if (error instanceof z.ZodError) {
      return NextResponse.json(
        { error: "Invalid request data", details: error.errors },
        { 
          status: 400,
          headers: {
            'Access-Control-Allow-Origin': process.env.NODE_ENV === 'production' ? 'https://app.earnlayerai.com' : 'http://localhost:3000',
            'Access-Control-Allow-Credentials': 'true',
          }
        }
      );
    }

    console.error("Error accepting agreement:", error);
    return NextResponse.json(
      { error: "Failed to accept agreement" },
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
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
      'Access-Control-Allow-Credentials': 'true',
    },
  });
}