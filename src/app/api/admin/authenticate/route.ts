import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import crypto from "crypto";
import jwt from "jsonwebtoken";

const authSchema = z.object({
  password: z.string().min(1, "Password is required"),
});

// Use JWT for session management when database is unavailable
const JWT_SECRET = process.env.BETTER_AUTH_SECRET || "fallback-secret-for-admin";

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { password } = authSchema.parse(body);

    // Check password against environment variable
    const adminPassword = process.env.ADMIN_PASSWORD;
    if (!adminPassword) {
      console.error("ADMIN_PASSWORD environment variable not set");
      return NextResponse.json(
        { error: "Admin authentication not configured" },
        { status: 500 }
      );
    }

    if (password !== adminPassword) {
      // Log failed attempt
      console.log(`Failed admin login attempt from IP: ${request.headers.get('x-forwarded-for') || 'unknown'}`);
      return NextResponse.json(
        { error: "Invalid password" },
        { status: 401 }
      );
    }

    // Generate JWT token instead of database session
    const expiresAt = new Date(Date.now() + (3600000)); // 1 hour
    const ipAddress = request.headers.get('x-forwarded-for') || request.headers.get('x-real-ip') || 'unknown';

    const token = jwt.sign({
      admin: true,
      ip: ipAddress,
      exp: Math.floor(expiresAt.getTime() / 1000)
    }, JWT_SECRET);

    // Log successful login
    console.log(`Successful admin login from IP: ${ipAddress}`);

    // Set secure cookie with JWT token
    const response = NextResponse.json({
      success: true,
      expiresAt: expiresAt.toISOString()
    });

    response.cookies.set('admin-session', token, {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: 3600, // 1 hour
      path: '/'
    });

    return response;

  } catch (error) {
    if (error instanceof z.ZodError) {
      return NextResponse.json(
        { error: "Invalid request", details: error.errors },
        { status: 400 }
      );
    }

    console.error("Admin authentication error:", error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}

export async function GET(request: NextRequest) {
  const token = request.cookies.get('admin-session')?.value;

  if (!token) {
    return NextResponse.json({ authenticated: false });
  }

  try {
    const decoded = jwt.verify(token, JWT_SECRET) as any;

    if (!decoded.admin || decoded.exp < Math.floor(Date.now() / 1000)) {
      return NextResponse.json({ authenticated: false });
    }

    return NextResponse.json({
      authenticated: true,
      expiresAt: new Date(decoded.exp * 1000).toISOString()
    });
  } catch (error) {
    console.error('Error verifying admin token:', error);
    return NextResponse.json({ authenticated: false });
  }
}

export async function DELETE(request: NextRequest) {
  const response = NextResponse.json({ success: true });
  response.cookies.delete('admin-session');

  return response;
}

// Helper function to check admin authentication (exported for use in other endpoints)
export async function isAdminAuthenticated(request: NextRequest): Promise<boolean> {
  const token = request.cookies.get('admin-session')?.value;

  console.log('Admin auth check:', {
    token: token ? 'present' : 'missing',
    path: request.nextUrl.pathname
  });

  if (!token) {
    console.log('No token found in cookies');
    return false;
  }

  try {
    const decoded = jwt.verify(token, JWT_SECRET) as any;
    const isValid = decoded.admin && decoded.exp > Math.floor(Date.now() / 1000);

    console.log('Token validation:', {
      hasAdminFlag: !!decoded.admin,
      isExpired: decoded.exp <= Math.floor(Date.now() / 1000),
      isValid
    });

    return isValid;
  } catch (error) {
    console.error('Error checking admin authentication:', error);
    return false;
  }
}