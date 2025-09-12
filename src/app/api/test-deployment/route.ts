import { NextResponse } from "next/server";

export async function GET() {
  return NextResponse.json({
    success: true,
    message: "API routing is working!",
    timestamp: new Date().toISOString(),
    environment: process.env.NODE_ENV,
  });
}