import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { creators, user } from "@/lib/db/schema";
import { eq } from "drizzle-orm";
import { auth } from "@/lib/auth/config";
import crypto from "crypto";

// Helper function to generate unique creator name
function generateCreatorName(email: string, name?: string): string {
  if (name) {
    return `${name} (${email.split('@')[0]})`;
  }
  const emailPrefix = email.split('@')[0];
  const randomSuffix = crypto.randomBytes(3).toString('hex');
  return `Creator ${emailPrefix}_${randomSuffix}`;
}

// GET /api/creator/profile - Check if user has creator profile
export async function GET(request: NextRequest) {
  try {
    console.log("🔍 [Creator Profile] Checking creator profile for authenticated user...");
    
    // Get session from Better Auth
    const session = await auth.api.getSession({
      headers: request.headers,
    });

    if (!session) {
      console.log("❌ [Creator Profile] No authenticated session found");
      return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
    }

    const userId = session.user.id;
    console.log("✅ [Creator Profile] Authenticated user ID:", userId);

    // Look up creator profile by user_id
    const creatorProfile = await db
      .select({
        id: creators.id,
        name: creators.name,
        email: creators.email,
        userId: creators.userId,
      })
      .from(creators)
      .where(eq(creators.userId, userId))
      .limit(1);

    if (creatorProfile.length > 0) {
      console.log("✅ [Creator Profile] Found existing creator profile:", creatorProfile[0].id);
      return NextResponse.json({
        hasCreatorProfile: true,
        creatorProfile: creatorProfile[0]
      });
    } else {
      console.log("❌ [Creator Profile] No creator profile found for user:", userId);
      return NextResponse.json({
        hasCreatorProfile: false,
        userId: userId,
        userEmail: session.user.email,
        userName: session.user.name
      });
    }
  } catch (error) {
    console.error("❌ [Creator Profile] Error checking creator profile:", error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}

// POST /api/creator/profile - Create creator profile for authenticated user
export async function POST(request: NextRequest) {
  try {
    console.log("🎯 [Creator Profile] Creating creator profile for authenticated user...");
    
    // Get session from Better Auth
    const session = await auth.api.getSession({
      headers: request.headers,
    });

    if (!session) {
      console.log("❌ [Creator Profile] No authenticated session found");
      return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
    }

    const userId = session.user.id;
    const userEmail = session.user.email;
    const userName = session.user.name;
    
    console.log("✅ [Creator Profile] Authenticated user:", { userId, userEmail, userName });

    // Check if creator already exists
    const existingCreator = await db
      .select()
      .from(creators)
      .where(eq(creators.userId, userId))
      .limit(1);

    if (existingCreator.length > 0) {
      console.log("⚠️ [Creator Profile] Creator already exists:", existingCreator[0].id);
      return NextResponse.json({
        success: true,
        creatorProfile: existingCreator[0],
        message: "Creator profile already exists"
      });
    }

    // Generate creator name
    const creatorName = generateCreatorName(userEmail, userName);
    
    // Create new creator profile
    const newCreator = await db
      .insert(creators)
      .values({
        userId: userId,
        name: creatorName,
        email: userEmail,
      })
      .returning();

    console.log("✅ [Creator Profile] Created new creator profile:", newCreator[0].id);

    return NextResponse.json({
      success: true,
      creatorProfile: newCreator[0],
      message: "Creator profile created successfully"
    });
    
  } catch (error) {
    console.error("❌ [Creator Profile] Error creating creator profile:", error);
    return NextResponse.json(
      { error: "Internal server error" },
      { status: 500 }
    );
  }
}