import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { users } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import crypto from "crypto";

// POST /api/users - Create or update user
export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const { user: userData, provider = "google" } = body;

    if (!userData || !userData.email || !userData.name) {
      return NextResponse.json(
        { error: "Missing required user data" },
        { status: 400 }
      );
    }

    // Generate user ID if not provided
    const userId = userData.id || crypto.randomUUID();

    // Upsert user
    const newUser = {
      id: userId,
      email: userData.email,
      name: userData.name,
      picture: userData.picture || null,
      emailVerified: userData.emailVerified || false,
      provider,
    };

    const result = await db
      .insert(users)
      .values(newUser)
      .onConflictDoUpdate({
        target: users.id,
        set: {
          email: newUser.email,
          name: newUser.name,
          picture: newUser.picture,
          emailVerified: newUser.emailVerified,
          updatedAt: new Date(),
        },
      })
      .returning();

    return NextResponse.json(result[0]);
  } catch (error) {
    console.error("Error creating/updating user:", error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}

// GET /api/users - Get user by ID or email
export async function GET(request: NextRequest) {
  try {
    const { searchParams } = new URL(request.url);
    const id = searchParams.get("id");
    const email = searchParams.get("email");

    if (!id && !email) {
      return NextResponse.json(
        { error: "Must provide either id or email parameter" },
        { status: 400 }
      );
    }

    let user;
    if (id) {
      user = await db.select().from(users).where(eq(users.id, id)).limit(1);
    } else if (email) {
      user = await db.select().from(users).where(eq(users.email, email)).limit(1);
    }

    if (!user || user.length === 0) {
      return NextResponse.json(
        { error: "User not found" },
        { status: 404 }
      );
    }

    return NextResponse.json(user[0]);
  } catch (error) {
    console.error("Error fetching user:", error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}