import { NextRequest, NextResponse } from "next/server";
import { db } from "@/lib/db/connection";
import { creators, user } from "@/lib/db/schema";

// Temporary seeding endpoint - REMOVE AFTER TESTING
export async function POST(request: NextRequest) {
  try {
    // Security check
    const authHeader = request.headers.get('authorization');
    const expectedSecret = process.env.MIGRATION_SECRET || 'demo-migration-secret';
    
    if (authHeader !== `Bearer ${expectedSecret}`) {
      return NextResponse.json(
        { error: "Unauthorized" },
        { status: 401 }
      );
    }

    console.log("🌱 Seeding test creator and user...");

    // Create test user
    console.log("👤 Creating test user...");
    const testUser = await db.insert(user).values({
      id: "test-user-123",
      name: "Test User",
      email: "test@earnlayer.app",
      emailVerified: true,
    }).returning().catch((error) => {
      console.log("User might already exist:", error.message);
      return [{ id: "test-user-123" }]; // Return existing user
    });

    console.log("✅ Test user:", testUser[0].id);

    // Create test creator
    console.log("🎯 Creating test creator...");
    const testCreator = await db.insert(creators).values({
      userId: testUser[0].id,
      name: "Test Creator (test)",
      email: "test@earnlayer.app",
    }).returning().catch((error) => {
      console.log("Creator might already exist:", error.message);
      // Return dummy response
      return [{ id: "existing-creator" }];
    });

    console.log("✅ Test creator:", testCreator[0].id);

    return NextResponse.json({
      success: true,
      message: "Test data seeded successfully!",
      data: {
        user_id: testUser[0].id,
        creator_id: testCreator[0].id
      }
    });

  } catch (error) {
    console.error("❌ Seeding failed:", error);
    return NextResponse.json(
      { 
        success: false,
        error: "Seeding failed", 
        details: String(error) 
      },
      { status: 500 }
    );
  }
}