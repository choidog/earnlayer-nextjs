import { db } from "../src/lib/db/connection";
import { ads, creators } from "../src/lib/db/schema";
import { embeddingService } from "../src/lib/services/embeddings";
import { vectorSearchService } from "../src/lib/services/vector-search";
import { sql } from "drizzle-orm";

async function testDatabaseConnection() {
  console.log("🔌 Testing database connection...");
  
  try {
    // Test basic connection
    const result = await db.execute(sql`SELECT NOW() as current_time`);
    console.log("✅ Database connected successfully");
    console.log("⏰ Current time:", result[0].current_time);
    
    // Test pgvector extension
    const vectorCheck = await db.execute(
      sql`SELECT * FROM pg_extension WHERE extname = 'vector'`
    );
    
    if (vectorCheck.length > 0) {
      console.log("✅ pgvector extension is installed");
    } else {
      console.log("❌ pgvector extension not found!");
      return false;
    }
    
    return true;
  } catch (error) {
    console.error("❌ Database connection failed:", error);
    return false;
  }
}

async function testTableStructure() {
  console.log("\n📊 Testing table structure...");
  
  try {
    // Check if main tables exist
    const tableChecks = await Promise.all([
      db.execute(sql`SELECT COUNT(*) as count FROM creators`),
      db.execute(sql`SELECT COUNT(*) as count FROM ads`),
      db.execute(sql`SELECT COUNT(*) as count FROM ad_campaigns`),
    ]);
    
    console.log("✅ Table counts:");
    console.log(`   Creators: ${tableChecks[0][0].count}`);
    console.log(`   Ads: ${tableChecks[1][0].count}`);
    console.log(`   Campaigns: ${tableChecks[2][0].count}`);
    
    return true;
  } catch (error) {
    console.error("❌ Table structure test failed:", error);
    return false;
  }
}

async function testEmbeddingService() {
  console.log("\n🤖 Testing OpenAI embeddings service...");
  
  try {
    const testText = "This is a test advertisement for a great product";
    const embedding = await embeddingService.generateEmbedding(testText);
    
    console.log("✅ Embedding generated successfully");
    console.log(`   Dimensions: ${embedding.length}`);
    console.log(`   First few values: [${embedding.slice(0, 5).join(", ")}...]`);
    
    return embedding.length === 1536; // Verify correct dimensions
  } catch (error) {
    console.error("❌ Embedding service test failed:", error);
    return false;
  }
}

async function testVectorSearch() {
  console.log("\n🔍 Testing vector search functionality...");
  
  try {
    // Test with sample search (will return empty if no ads have embeddings yet)
    const results = await vectorSearchService.searchAds("technology product", {
      limit: 5,
      threshold: 0.1 // Low threshold for testing
    });
    
    console.log("✅ Vector search executed successfully");
    console.log(`   Results found: ${results.length}`);
    
    if (results.length > 0) {
      console.log(`   Top result similarity: ${results[0].similarity.toFixed(3)}`);
      console.log(`   Top result title: "${results[0].ad.title}"`);
    } else {
      console.log("   ℹ️  No results found (ads may need embeddings)");
    }
    
    return true;
  } catch (error) {
    console.error("❌ Vector search test failed:", error);
    return false;
  }
}

async function runAllTests() {
  console.log("🧪 Running EarnLayer Next.js Setup Tests\n");
  
  const tests = [
    { name: "Database Connection", test: testDatabaseConnection },
    { name: "Table Structure", test: testTableStructure },
    { name: "Embedding Service", test: testEmbeddingService },
    { name: "Vector Search", test: testVectorSearch },
  ];
  
  const results = [];
  
  for (const { name, test } of tests) {
    try {
      const result = await test();
      results.push({ name, passed: result });
    } catch (error) {
      console.error(`❌ Test "${name}" threw an error:`, error);
      results.push({ name, passed: false });
    }
  }
  
  // Summary
  console.log("\n📋 Test Summary:");
  console.log("==================");
  
  let allPassed = true;
  for (const { name, passed } of results) {
    const status = passed ? "✅ PASS" : "❌ FAIL";
    console.log(`${status} ${name}`);
    if (!passed) allPassed = false;
  }
  
  console.log("\n" + (allPassed ? "🎉 All tests passed!" : "⚠️  Some tests failed"));
  
  process.exit(allPassed ? 0 : 1);
}

// Run tests if this file is executed directly
if (require.main === module) {
  runAllTests().catch(console.error);
}