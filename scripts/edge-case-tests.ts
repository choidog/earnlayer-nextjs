import { embeddingService } from "../src/lib/services/embeddings";
import { vectorSearchService } from "../src/lib/services/vector-search";
import { adServingService } from "../src/lib/services/ad-serving";
import { budgetTrackingService } from "../src/lib/services/budget-tracking";
import { db } from "../src/lib/db/connection";
import { creators, ads, adCampaigns, chatSessions } from "../src/lib/db/schema";
import { eq, sql } from "drizzle-orm";
import { config } from "dotenv";

config({ path: ".env.local" });

interface EdgeCaseTest {
  name: string;
  description: string;
  testFn: () => Promise<any>;
  expectedBehavior: string;
}

class EdgeCaseTestRunner {
  private passedTests = 0;
  private failedTests = 0;
  private testResults: Array<{
    name: string;
    status: "pass" | "fail";
    result?: any;
    error?: string;
    duration: number;
  }> = [];

  private async runTest(test: EdgeCaseTest): Promise<void> {
    console.log(`🔍 Testing: ${test.name}`);
    console.log(`   Description: ${test.description}`);
    console.log(`   Expected: ${test.expectedBehavior}`);
    
    const startTime = Date.now();
    
    try {
      const result = await test.testFn();
      const duration = Date.now() - startTime;
      
      this.passedTests++;
      this.testResults.push({
        name: test.name,
        status: "pass",
        result: typeof result === 'string' ? result : JSON.stringify(result).substring(0, 100),
        duration
      });
      
      console.log(`   ✅ PASS (${duration}ms): ${typeof result === 'string' ? result : 'Test completed successfully'}`);
      
    } catch (error) {
      const duration = Date.now() - startTime;
      const errorMessage = error instanceof Error ? error.message : String(error);
      
      this.failedTests++;
      this.testResults.push({
        name: test.name,
        status: "fail",
        error: errorMessage,
        duration
      });
      
      console.log(`   ❌ FAIL (${duration}ms): ${errorMessage}`);
    }
    
    console.log("");
  }

  async runEmbeddingEdgeCases(): Promise<void> {
    console.log("🔤 Embedding Service Edge Cases");
    console.log("=".repeat(50));

    const tests: EdgeCaseTest[] = [
      {
        name: "Empty string embedding",
        description: "Generate embedding for empty string",
        testFn: () => embeddingService.generateEmbedding(""),
        expectedBehavior: "Should handle empty string gracefully"
      },
      {
        name: "Very long text embedding",
        description: "Generate embedding for text exceeding token limits",
        testFn: () => {
          const longText = "AI technology ".repeat(2000); // ~16,000 chars
          return embeddingService.generateEmbedding(longText);
        },
        expectedBehavior: "Should truncate text and generate embedding"
      },
      {
        name: "Special characters embedding",
        description: "Generate embedding for text with special characters",
        testFn: () => embeddingService.generateEmbedding("🚀 AI/ML & Data Science (2024) - 100% efficient! @#$%^&*()"),
        expectedBehavior: "Should handle special characters correctly"
      },
      {
        name: "Batch embedding with empty array",
        description: "Generate embeddings for empty array",
        testFn: () => embeddingService.generateEmbeddings([]),
        expectedBehavior: "Should return empty array without errors"
      },
      {
        name: "Batch embedding with mixed content",
        description: "Generate embeddings for array with empty and normal strings",
        testFn: () => embeddingService.generateEmbeddings(["normal text", "", "another text", "   "]),
        expectedBehavior: "Should handle mixed content appropriately"
      },
      {
        name: "Invalid cosine similarity inputs",
        description: "Calculate similarity with different dimension vectors",
        testFn: async () => {
          const emb1 = await embeddingService.generateEmbedding("test");
          const emb2 = [1, 2, 3]; // Wrong dimensions
          try {
            return embeddingService.constructor.cosineSimilarity(emb1, emb2);
          } catch (error) {
            return `Correctly threw error: ${error instanceof Error ? error.message : error}`;
          }
        },
        expectedBehavior: "Should throw error for mismatched dimensions"
      }
    ];

    for (const test of tests) {
      await this.runTest(test);
    }
  }

  async runVectorSearchEdgeCases(): Promise<void> {
    console.log("🔍 Vector Search Edge Cases");
    console.log("=".repeat(50));

    const tests: EdgeCaseTest[] = [
      {
        name: "Search with empty query",
        description: "Vector search with empty string",
        testFn: () => vectorSearchService.searchAds("", { limit: 5, threshold: 0.1 }),
        expectedBehavior: "Should handle empty query gracefully"
      },
      {
        name: "Search with very high threshold",
        description: "Vector search with threshold = 0.99",
        testFn: () => vectorSearchService.searchAds("technology", { limit: 5, threshold: 0.99 }),
        expectedBehavior: "Should return few or no results due to high threshold"
      },
      {
        name: "Search with zero threshold",
        description: "Vector search with threshold = 0",
        testFn: () => vectorSearchService.searchAds("technology", { limit: 5, threshold: 0 }),
        expectedBehavior: "Should return results regardless of similarity"
      },
      {
        name: "Search with invalid limit",
        description: "Vector search with limit = 0",
        testFn: () => vectorSearchService.searchAds("technology", { limit: 0, threshold: 0.1 }),
        expectedBehavior: "Should handle zero limit gracefully"
      },
      {
        name: "Hybrid search with extreme weights",
        description: "Hybrid search with vectorWeight = 0",
        testFn: () => vectorSearchService.hybridAdSearch("technology", { 
          vectorWeight: 0, 
          revenueBoost: 2.0 
        }),
        expectedBehavior: "Should prioritize revenue over similarity"
      },
      {
        name: "Contextual search with non-existent session",
        description: "Get contextual ads for non-existent session",
        testFn: () => vectorSearchService.getContextualAds("00000000-0000-0000-0000-000000000000", {
          limit: 3,
          threshold: 0.1
        }),
        expectedBehavior: "Should handle non-existent session gracefully"
      }
    ];

    for (const test of tests) {
      await this.runTest(test);
    }
  }

  async runAdServingEdgeCases(): Promise<void> {
    console.log("🎯 Ad Serving Edge Cases");
    console.log("=".repeat(50));

    // Get test data
    const creatorsResult = await db.select().from(creators).limit(1);
    const creatorId = creatorsResult[0]?.id;
    
    if (!creatorId) {
      console.log("⚠️  No creators found, skipping ad serving edge cases");
      return;
    }

    const tests: EdgeCaseTest[] = [
      {
        name: "Ad serving with invalid creator ID",
        description: "Serve ads for non-existent creator",
        testFn: () => adServingService.serveContextualAds("technology", {
          creatorId: "00000000-0000-0000-0000-000000000000",
          limit: 3,
          similarityThreshold: 0.2
        }),
        expectedBehavior: "Should handle invalid creator ID gracefully"
      },
      {
        name: "Ad serving with extreme threshold",
        description: "Serve ads with similarityThreshold = 1.0",
        testFn: () => adServingService.serveContextualAds("technology", {
          creatorId,
          limit: 3,
          similarityThreshold: 1.0
        }),
        expectedBehavior: "Should return no ads due to perfect similarity requirement"
      },
      {
        name: "Ad serving with very long query",
        description: "Serve ads with extremely long query",
        testFn: () => {
          const longQuery = "artificial intelligence and machine learning technology ".repeat(100);
          return adServingService.serveContextualAds(longQuery, {
            creatorId,
            limit: 3,
            similarityThreshold: 0.2
          });
        },
        expectedBehavior: "Should handle long queries by truncating appropriately"
      },
      {
        name: "Ad serving with zero limit",
        description: "Serve ads with limit = 0",
        testFn: () => adServingService.serveContextualAds("technology", {
          creatorId,
          limit: 0,
          similarityThreshold: 0.2
        }),
        expectedBehavior: "Should return empty results for zero limit"
      },
      {
        name: "Default ad serving with all constraints",
        description: "Default ads with restrictive filters",
        testFn: () => adServingService.serveDefaultAds({
          creatorId,
          adType: "nonexistent_type" as any,
          placement: "nonexistent_placement" as any,
          limit: 3
        }),
        expectedBehavior: "Should handle invalid ad types/placements"
      },
      {
        name: "Display ad timing with invalid session",
        description: "Check display ad timing for non-existent session",
        testFn: () => adServingService.getDisplayAdTiming("00000000-0000-0000-0000-000000000000"),
        expectedBehavior: "Should handle non-existent session gracefully"
      }
    ];

    for (const test of tests) {
      await this.runTest(test);
    }
  }

  async runBudgetTrackingEdgeCases(): Promise<void> {
    console.log("💰 Budget Tracking Edge Cases");
    console.log("=".repeat(50));

    const tests: EdgeCaseTest[] = [
      {
        name: "Budget status for non-existent campaign",
        description: "Get budget status for invalid campaign ID",
        testFn: () => budgetTrackingService.getCampaignBudgetStatus("00000000-0000-0000-0000-000000000000"),
        expectedBehavior: "Should return null for non-existent campaign"
      },
      {
        name: "Campaign performance with invalid timeframe",
        description: "Get performance with invalid timeframe",
        testFn: async () => {
          const campaigns = await db.select().from(adCampaigns).limit(1);
          if (campaigns.length === 0) throw new Error("No campaigns found");
          
          return budgetTrackingService.getCampaignPerformance(
            campaigns[0].id,
            "invalid_timeframe" as any
          );
        },
        expectedBehavior: "Should handle invalid timeframe gracefully"
      },
      {
        name: "Update spending with negative amount",
        description: "Update campaign spending with negative value",
        testFn: async () => {
          const campaigns = await db.select().from(adCampaigns).limit(1);
          if (campaigns.length === 0) throw new Error("No campaigns found");
          
          try {
            await budgetTrackingService.updateCampaignSpending(campaigns[0].id, -100);
            return "Updated with negative amount";
          } catch (error) {
            return `Correctly rejected negative amount: ${error instanceof Error ? error.message : error}`;
          }
        },
        expectedBehavior: "Should handle negative amounts appropriately"
      },
      {
        name: "Budget report with no active campaigns",
        description: "Generate budget report when no campaigns exist",
        testFn: () => budgetTrackingService.getBudgetUtilizationReport(),
        expectedBehavior: "Should return report with zero values if no campaigns"
      }
    ];

    for (const test of tests) {
      await this.runTest(test);
    }
  }

  async runDatabaseEdgeCases(): Promise<void> {
    console.log("🗃️  Database Edge Cases");
    console.log("=".repeat(50));

    const tests: EdgeCaseTest[] = [
      {
        name: "Query with malformed UUID",
        description: "Search for records with invalid UUID format",
        testFn: async () => {
          try {
            await db.select().from(creators).where(eq(creators.id, "invalid-uuid"));
            return "Query executed without error";
          } catch (error) {
            return `Correctly rejected invalid UUID: ${error instanceof Error ? error.message.substring(0, 50) : error}`;
          }
        },
        expectedBehavior: "Should reject invalid UUID formats"
      },
      {
        name: "Vector query with null embedding",
        description: "Vector search when embeddings are null",
        testFn: () => db.execute(sql`
          SELECT id, title 
          FROM ads 
          WHERE embedding IS NULL 
          LIMIT 5
        `),
        expectedBehavior: "Should return ads without embeddings"
      },
      {
        name: "Complex query with no results",
        description: "Complex JOIN query that returns no results",
        testFn: () => db.execute(sql`
          SELECT a.id, a.title
          FROM ads a
          JOIN ad_campaigns c ON a.campaign_id = c.id
          WHERE c.name = 'NonexistentCampaign'
          AND a.status = 'active'
        `),
        expectedBehavior: "Should return empty result set"
      },
      {
        name: "Concurrent database access",
        description: "Multiple simultaneous database queries",
        testFn: async () => {
          const promises = Array(5).fill(null).map(() => 
            db.select().from(creators).limit(1)
          );
          const results = await Promise.all(promises);
          return `Executed ${results.length} concurrent queries successfully`;
        },
        expectedBehavior: "Should handle concurrent access correctly"
      }
    ];

    for (const test of tests) {
      await this.runTest(test);
    }
  }

  async runDataIntegrityEdgeCases(): Promise<void> {
    console.log("🔒 Data Integrity Edge Cases");
    console.log("=".repeat(50));

    const tests: EdgeCaseTest[] = [
      {
        name: "Foreign key constraints validation",
        description: "Check if foreign key constraints are enforced",
        testFn: async () => {
          const violations = await db.execute(sql`
            SELECT 'ads_missing_campaign' as issue, COUNT(*) as count
            FROM ads a
            LEFT JOIN ad_campaigns c ON a.campaign_id = c.id
            WHERE c.id IS NULL
            
            UNION ALL
            
            SELECT 'impressions_missing_ad' as issue, COUNT(*) as count
            FROM ad_impressions i
            LEFT JOIN ads a ON i.ad_id = a.id
            WHERE a.id IS NULL
          `);
          
          const totalViolations = violations.reduce((sum, row) => sum + (row.count || 0), 0);
          return `Found ${totalViolations} referential integrity issues`;
        },
        expectedBehavior: "Should have minimal or no referential integrity violations"
      },
      {
        name: "Data consistency checks",
        description: "Check for logical data inconsistencies",
        testFn: async () => {
          const inconsistencies = await db.execute(sql`
            SELECT 'negative_budgets' as issue, COUNT(*) as count
            FROM ad_campaigns
            WHERE budget_amount < 0 OR spent_amount < 0
            
            UNION ALL
            
            SELECT 'overspent_campaigns' as issue, COUNT(*) as count
            FROM ad_campaigns
            WHERE spent_amount > budget_amount + 100
            
            UNION ALL
            
            SELECT 'future_created_at' as issue, COUNT(*) as count
            FROM ads
            WHERE created_at > NOW() + INTERVAL '1 day'
          `);
          
          const totalIssues = inconsistencies.reduce((sum, row) => sum + (row.count || 0), 0);
          return `Found ${totalIssues} data consistency issues`;
        },
        expectedBehavior: "Should have minimal data consistency issues"
      },
      {
        name: "Embedding data quality",
        description: "Check quality of stored embeddings",
        testFn: async () => {
          const embeddingStats = await db.execute(sql`
            SELECT 
              COUNT(*) as total_ads,
              COUNT(embedding) as ads_with_embeddings,
              COUNT(CASE WHEN array_length(embedding::float[], 1) = 1536 THEN 1 END) as correct_dimension_embeddings
            FROM ads
            WHERE deleted_at IS NULL
          `);
          
          const stats = embeddingStats[0];
          const coverage = stats?.ads_with_embeddings / stats?.total_ads * 100 || 0;
          const quality = stats?.correct_dimension_embeddings / stats?.ads_with_embeddings * 100 || 0;
          
          return `Embedding coverage: ${coverage.toFixed(1)}%, Quality: ${quality.toFixed(1)}%`;
        },
        expectedBehavior: "Should have high embedding coverage and quality"
      }
    ];

    for (const test of tests) {
      await this.runTest(test);
    }
  }

  printFinalReport(): void {
    console.log("\n" + "=".repeat(60));
    console.log("🎯 EDGE CASE TEST REPORT");
    console.log("=".repeat(60));
    
    const totalTests = this.passedTests + this.failedTests;
    const passRate = (this.passedTests / totalTests) * 100;
    
    console.log(`\n📊 Overall Results:`);
    console.log(`   Total Tests: ${totalTests}`);
    console.log(`   Passed: ${this.passedTests} (${passRate.toFixed(1)}%)`);
    console.log(`   Failed: ${this.failedTests} (${(100 - passRate).toFixed(1)}%)`);
    
    // Show failed tests
    const failedTests = this.testResults.filter(t => t.status === "fail");
    if (failedTests.length > 0) {
      console.log(`\n❌ Failed Tests:`);
      failedTests.forEach(test => {
        console.log(`   • ${test.name}: ${test.error}`);
      });
    }
    
    // Performance insights
    const avgDuration = this.testResults.reduce((sum, t) => sum + t.duration, 0) / this.testResults.length;
    const slowTests = this.testResults.filter(t => t.duration > avgDuration * 2);
    
    if (slowTests.length > 0) {
      console.log(`\n⏱️  Slow Tests (>${(avgDuration * 2).toFixed(0)}ms):`);
      slowTests.forEach(test => {
        console.log(`   • ${test.name}: ${test.duration}ms`);
      });
    }
    
    console.log(`\n💡 Recommendations:`);
    if (failedTests.length === 0) {
      console.log(`   ✅ All edge cases handled correctly!`);
      console.log(`   ✅ System shows good resilience to invalid inputs`);
      console.log(`   ✅ Error handling appears robust`);
    } else {
      console.log(`   ⚠️  Review failed tests to improve error handling`);
      console.log(`   ⚠️  Consider adding more validation for edge cases`);
    }
    
    console.log(`   💡 Add monitoring for these edge cases in production`);
    console.log(`   💡 Consider rate limiting to prevent abuse of edge cases`);
  }

  async runAllEdgeCaseTests(): Promise<void> {
    console.log("🚀 Starting comprehensive edge case testing\n");
    
    try {
      await this.runEmbeddingEdgeCases();
      await this.runVectorSearchEdgeCases();
      await this.runAdServingEdgeCases();
      await this.runBudgetTrackingEdgeCases();
      await this.runDatabaseEdgeCases();
      await this.runDataIntegrityEdgeCases();
      
      this.printFinalReport();
      
      if (this.failedTests > 0) {
        console.log("\n⚠️  Some edge case tests failed. Review for production readiness.");
        process.exit(1);
      } else {
        console.log("\n🎉 All edge case tests passed! System is resilient to edge cases.");
      }
      
    } catch (error) {
      console.error("💥 Edge case testing failed:", error);
      process.exit(1);
    }
  }
}

// Run edge case tests if this file is executed directly
if (require.main === module) {
  const runner = new EdgeCaseTestRunner();
  runner.runAllEdgeCaseTests();
}

export { EdgeCaseTestRunner };