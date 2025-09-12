import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import crypto from "crypto";
import { db } from "@/lib/db/connection";
import { adminSessions } from "@/lib/db/schema";
import { eq, lt } from "drizzle-orm";

const authSchema = z.object({
  password: z.string().min(1, "Password is required"),
});

// Clean expired sessions periodically
const cleanupExpiredSessions = async () => {
  try {
    await db.delete(adminSessions).where(lt(adminSessions.expiresAt, new Date()));
  } catch (error) {
    console.error('Failed to cleanup expired sessions:', error);
  }
};

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
    const expiresAt = new Date(Date.now() + (3600000)); // 1 hour
    const ipAddress = request.headers.get('x-forwarded-for') || request.headers.get('x-real-ip') || 'unknown';

    // Clean up expired sessions first
    await cleanupExpiredSessions();

    // Store session in database
    await db.insert(adminSessions).values({
      sessionId,
      expiresAt,
      ipAddress
    });

    // Log successful login
    console.log(`Successful admin login from IP: ${request.headers.get('x-forwarded-for') || 'unknown'}`);

    // Set secure cookie
    const response = NextResponse.json({ 
      success: true,
      expiresAt: expiresAt.toISOString()
    });
    
    response.cookies.set('admin-session', sessionId, {
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
  const sessionId = request.cookies.get('admin-session')?.value;
  
  if (!sessionId) {
    return NextResponse.json({ authenticated: false });
  }

  try {
    const session = await db.select().from(adminSessions)
      .where(eq(adminSessions.sessionId, sessionId))
      .limit(1);

    if (session.length === 0 || session[0].expiresAt < new Date()) {
      // Clean up expired session
      if (session.length > 0) {
        await db.delete(adminSessions).where(eq(adminSessions.sessionId, sessionId));
      }
      return NextResponse.json({ authenticated: false });
    }

    return NextResponse.json({ 
      authenticated: true,
      expiresAt: session[0].expiresAt.toISOString()
    });
  } catch (error) {
    console.error('Error checking admin session:', error);
    return NextResponse.json({ authenticated: false });
  }
}

export async function DELETE(request: NextRequest) {
  const sessionId = request.cookies.get('admin-session')?.value;
  
  if (sessionId) {
    try {
      await db.delete(adminSessions).where(eq(adminSessions.sessionId, sessionId));
    } catch (error) {
      console.error('Error deleting admin session:', error);
    }
  }

  const response = NextResponse.json({ success: true });
  response.cookies.delete('admin-session');
  
  return response;
}

// Helper function to check admin authentication (exported for use in other endpoints)
export async function isAdminAuthenticated(request: NextRequest): Promise<boolean> {
  const sessionId = request.cookies.get('admin-session')?.value;
  
  console.log('Admin auth check:', {
    sessionId: sessionId ? 'present' : 'missing',
    path: request.nextUrl.pathname
  });
  
  if (!sessionId) {
    console.log('No session ID found in cookies');
    return false;
  }

  try {
    const session = await db.select().from(adminSessions)
      .where(eq(adminSessions.sessionId, sessionId))
      .limit(1);

    const isValid = session.length > 0 && session[0].expiresAt > new Date();
    
    console.log('Session validation:', {
      sessionExists: session.length > 0,
      isExpired: session.length > 0 ? session[0].expiresAt < new Date() : 'no-session',
      isValid
    });

    // Clean up expired session
    if (session.length > 0 && !isValid) {
      await db.delete(adminSessions).where(eq(adminSessions.sessionId, sessionId));
    }
    
    return isValid;
  } catch (error) {
    console.error('Error checking admin authentication:', error);
    return false;
  }
}