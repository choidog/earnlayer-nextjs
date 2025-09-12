import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import crypto from "crypto";

const authSchema = z.object({
  password: z.string().min(1, "Password is required"),
});

// Simple session storage for admin authentication
const adminSessions = new Map<string, { expires: number }>();

// Clean expired sessions every hour
setInterval(() => {
  const now = Date.now();
  for (const [sessionId, session] of adminSessions.entries()) {
    if (session.expires < now) {
      adminSessions.delete(sessionId);
    }
  }
}, 3600000);

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

    // Generate session ID
    const sessionId = crypto.randomBytes(32).toString('hex');
    const expires = Date.now() + (3600000); // 1 hour

    // Store session
    adminSessions.set(sessionId, { expires });

    // Log successful login
    console.log(`Successful admin login from IP: ${request.headers.get('x-forwarded-for') || 'unknown'}`);

    // Set secure cookie
    const response = NextResponse.json({ 
      success: true,
      expiresAt: new Date(expires).toISOString()
    });
    
    response.cookies.set('admin-session', sessionId, {
      httpOnly: true,
      secure: process.env.NODE_ENV === 'production',
      sameSite: 'strict',
      maxAge: 3600, // 1 hour
      path: '/admin'
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
  const sessionId = request.cookies.get('admin-session')?.value;
  
  if (!sessionId) {
    return NextResponse.json({ authenticated: false });
  }

  const session = adminSessions.get(sessionId);
  if (!session || session.expires < Date.now()) {
    // Clean up expired session
    adminSessions.delete(sessionId);
    return NextResponse.json({ authenticated: false });
  }

  return NextResponse.json({ 
    authenticated: true,
    expiresAt: new Date(session.expires).toISOString()
  });
}

export async function DELETE(request: NextRequest) {
  const sessionId = request.cookies.get('admin-session')?.value;
  
  if (sessionId) {
    adminSessions.delete(sessionId);
  }

  const response = NextResponse.json({ success: true });
  response.cookies.delete('admin-session');
  
  return response;
}

// Helper function to check admin authentication (exported for use in other endpoints)
export function isAdminAuthenticated(request: NextRequest): boolean {
  const sessionId = request.cookies.get('admin-session')?.value;
  
  if (!sessionId) return false;

  const session = adminSessions.get(sessionId);
  return session !== undefined && session.expires > Date.now();
}