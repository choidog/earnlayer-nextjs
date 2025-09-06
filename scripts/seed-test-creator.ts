#!/usr/bin/env tsx
/**
 * Seed Script: Create test creator with user for testing
 */

import { db } from "../src/lib/db/connection";
import { creators, user } from "../src/lib/db/schema";

async function seedTestCreator() {
  console.log("🌱 Seeding test creator and user...");

  try {
    // Create test user
    console.log("👤 Creating test user...");
    const testUser = await db.insert(user).values({
      id: "test-user-123",
      name: "Test User",
      email: "test@earnlayer.app",
      emailVerified: true,
    }).returning();

    console.log("✅ Test user created:", testUser[0].id);

    // Create test creator
    console.log("🎯 Creating test creator...");
    const testCreator = await db.insert(creators).values({
      userId: testUser[0].id,
      name: "Test Creator (test)",
      email: "test@earnlayer.app",
    }).returning();

    console.log("✅ Test creator created:", testCreator[0].id);

    console.log("🎉 Test data seeded successfully!");
    console.log("   User ID:", testUser[0].id);
    console.log("   Creator ID:", testCreator[0].id);

  } catch (error) {
    console.error("❌ Seeding failed:", error);
    process.exit(1);
  }
}

// Run seeding
if (require.main === module) {
  seedTestCreator()
    .then(() => process.exit(0))
    .catch(() => process.exit(1));
}

export { seedTestCreator };