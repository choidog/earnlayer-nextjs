import { NextRequest, NextResponse } from "next/server";

export async function GET(request: NextRequest) {
  return NextResponse.json({
    success: true,
    message: "Test endpoint working",
    timestamp: new Date().toISOString()
  }, {
    headers: {
      'Access-Control-Allow-Origin': 'https://app.earnlayerai.com',
      'Access-Control-Allow-Credentials': 'true',
    }
  });
}