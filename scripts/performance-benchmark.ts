import { embeddingService } from "../src/lib/services/embeddings";
import { vectorSearchService } from "../src/lib/services/vector-search";
import { adServingService } from "../src/lib/services/ad-serving";
import { db } from "../src/lib/db/connection";
import { creators, chatSessions, ads } from "../src/lib/db/schema";
import { sql } from "drizzle-orm";
import { config } from "dotenv";

config({ path: ".env.local" });

interface BenchmarkResult {
  operation: string;
  iterations: number;
  totalTime: number;
  averageTime: number;
  minTime: number;
  maxTime: number;
  throughput: number; // operations per second
  memoryUsage?: {
    before: number;
    after: number;
    delta: number;
  };
}

interface LoadTestResult {
  scenario: string;
  concurrency: number;
  totalRequests: number;
  successfulRequests: number;
  failedRequests: number;
  averageResponseTime: number;
  p95ResponseTime: number;
  p99ResponseTime: number;
  requestsPerSecond: number;
  errors: string[];
}

class PerformanceBenchmark {
  private results: BenchmarkResult[] = [];
  private loadTestResults: LoadTestResult[] = [];

  private getMemoryUsage(): number {
    const usage = process.memoryUsage();
    return usage.heapUsed / 1024 / 1024; // MB
  }

  private async measureOperation<T>(
    operation: string,
    fn: () => Promise<T>,
    iterations: number = 10,
    warmup: number = 2
  ): Promise<BenchmarkResult> {
    console.log(`📊 Benchmarking: ${operation} (${iterations} iterations)`);

    // Warmup runs
    for (let i = 0; i < warmup; i++) {
      try {
        await fn();
      } catch (error) {
        console.warn(`Warmup ${i+1} failed:`, error);
      }
    }

    // Actual benchmark
    const times: number[] = [];
    const memBefore = this.getMemoryUsage();
    
    for (let i = 0; i < iterations; i++) {
      const start = process.hrtime.bigint();
      
      try {
        await fn();
        const end = process.hrtime.bigint();
        const timeMs = Number(end - start) / 1_000_000;
        times.push(timeMs);
        
        if (i % Math.max(1, Math.floor(iterations / 4)) === 0) {
          process.stdout.write(`   Progress: ${i+1}/${iterations}\r`);
        }
      } catch (error) {
        console.warn(`Iteration ${i+1} failed:`, error);
        times.push(Infinity); // Mark as failed
      }
    }
    
    const memAfter = this.getMemoryUsage();
    console.log(`   Progress: ${iterations}/${iterations} ✓`);

    const validTimes = times.filter(t => t !== Infinity);
    const totalTime = validTimes.reduce((a, b) => a + b, 0);
    const averageTime = totalTime / validTimes.length;
    const minTime = Math.min(...validTimes);
    const maxTime = Math.max(...validTimes);
    const throughput = 1000 / averageTime; // ops/second

    const result: BenchmarkResult = {
      operation,
      iterations: validTimes.length,
      totalTime,
      averageTime,
      minTime,
      maxTime,
      throughput,
      memoryUsage: {
        before: memBefore,
        after: memAfter,
        delta: memAfter - memBefore
      }
    };

    this.results.push(result);
    return result;
  }

  async benchmarkEmbeddings(): Promise<void> {
    console.log("\n🔤 Embedding Service Benchmarks");
    console.log("-".repeat(40));

    const testTexts = [
      "AI and machine learning solutions for businesses",
      "Cloud computing infrastructure and DevOps tools",
      "Digital marketing and customer engagement platforms",
      "E-commerce and online retail solutions",
      "Cybersecurity and data protection services"
    ];

    // Single embedding generation
    await this.measureOperation(
      "Single embedding generation",
      () => embeddingService.generateEmbedding(testTexts[0]),
      20
    );

    // Batch embedding generation
    await this.measureOperation(
      "Batch embedding (5 texts)",
      () => embeddingService.generateEmbeddings(testTexts),
      10
    );

    // Cosine similarity calculation
    const emb1 = await embeddingService.generateEmbedding(testTexts[0]);
    const emb2 = await embeddingService.generateEmbedding(testTexts[1]);
    
    await this.measureOperation(
      "Cosine similarity calculation",
      () => Promise.resolve(embeddingService.constructor.cosineSimilarity(emb1, emb2)),
      100
    );
  }

  async benchmarkVectorSearch(): Promise<void> {
    console.log("\n🔍 Vector Search Benchmarks");
    console.log("-".repeat(40));

    const testQueries = [
      "artificial intelligence technology",
      "cloud computing solutions", 
      "marketing automation tools",
      "e-commerce platforms",
      "cybersecurity solutions"
    ];

    // Basic vector search
    await this.measureOperation(
      "Vector search (5 results)",
      () => vectorSearchService.searchAds(testQueries[0], { limit: 5, threshold: 0.2 }),
      15
    );

    // Hybrid search with revenue optimization
    await this.measureOperation(
      "Hybrid search (vector + revenue)",
      () => vectorSearchService.hybridAdSearch(testQueries[1], { 
        limit: 5, 
        vectorWeight: 0.7, 
        revenueBoost: 1.2 
      }),
      15
    );

    // Contextual search with conversation history
    const sessions = await db.select().from(chatSessions).limit(1);
    const sessionId = sessions[0]?.id;

    if (sessionId) {
      await this.measureOperation(
        "Contextual search (conversation history)",
        () => vectorSearchService.getContextualAds(sessionId, { 
          limit: 3, 
          threshold: 0.2,
          lookbackMessages: 10 
        }),
        10
      );
    }
  }

  async benchmarkAdServing(): Promise<void> {
    console.log("\n🎯 Ad Serving Benchmarks");
    console.log("-".repeat(40));

    // Get test data
    const creatorsResult = await db.select().from(creators).limit(1);
    const creatorId = creatorsResult[0]?.id;
    const sessionResult = await db.select().from(chatSessions).limit(1);
    const sessionId = sessionResult[0]?.id;

    if (!creatorId) {
      console.log("⚠️  No creators found, skipping ad serving benchmarks");
      return;
    }

    const testQuery = "cloud infrastructure and DevOps tools";

    // Contextual ad serving
    await this.measureOperation(
      "Contextual ad serving",
      () => adServingService.serveContextualAds(testQuery, {
        creatorId,
        sessionId,
        limit: 3,
        similarityThreshold: 0.25
      }),
      15
    );

    // Conversation-based ad serving
    if (sessionId) {
      await this.measureOperation(
        "Conversation-based ad serving",
        () => adServingService.serveConversationAds(sessionId, {
          creatorId,
          limit: 3,
          contextualMessages: 10
        }),
        10
      );
    }

    // Default ad serving (fallback)
    await this.measureOperation(
      "Default/fallback ad serving",
      () => adServingService.serveDefaultAds({
        creatorId,
        limit: 3
      }),
      20
    );
  }

  async benchmarkDatabaseOperations(): Promise<void> {
    console.log("\n🗃️  Database Operation Benchmarks");
    console.log("-".repeat(40));

    // Simple SELECT query
    await this.measureOperation(
      "Simple SELECT (ads table)",
      () => db.select().from(ads).limit(10),
      25
    );

    // Complex JOIN query
    await this.measureOperation(
      "Complex JOIN query",
      () => db.execute(sql`
        SELECT a.id, a.title, c.name as campaign_name, cr.name as creator_name
        FROM ads a
        JOIN ad_campaigns c ON a.campaign_id = c.id
        JOIN creators cr ON c.advertiser_id = cr.id
        WHERE a.status = 'active'
        LIMIT 10
      `),
      15
    );

    // Vector similarity query (if embeddings exist)
    const embeddingQuery = `[${Array(1536).fill(0.1).join(',')}]`;
    await this.measureOperation(
      "Vector similarity query",
      () => db.execute(sql`
        SELECT id, title, embedding <-> ${embeddingQuery}::vector as distance
        FROM ads
        WHERE embedding IS NOT NULL
        ORDER BY embedding <-> ${embeddingQuery}::vector
        LIMIT 5
      `),
      10
    );
  }

  async runLoadTest(
    scenario: string,
    testFn: () => Promise<any>,
    options: {
      concurrency: number;
      totalRequests: number;
      timeout?: number;
    }
  ): Promise<LoadTestResult> {
    console.log(`\n⚡ Load Test: ${scenario}`);
    console.log(`   Concurrency: ${options.concurrency}, Total: ${options.totalRequests}`);
    
    const startTime = Date.now();
    const responseTimes: number[] = [];
    const errors: string[] = [];
    let completedRequests = 0;
    let successfulRequests = 0;
    let failedRequests = 0;

    // Create request batches
    const batchSize = options.concurrency;
    const batches = Math.ceil(options.totalRequests / batchSize);

    for (let batch = 0; batch < batches; batch++) {
      const batchStart = Date.now();
      const requestsInBatch = Math.min(batchSize, options.totalRequests - completedRequests);
      
      const batchPromises = Array(requestsInBatch).fill(null).map(async () => {
        const requestStart = Date.now();
        
        try {
          await testFn();
          const responseTime = Date.now() - requestStart;
          responseTimes.push(responseTime);
          successfulRequests++;
        } catch (error) {
          failedRequests++;
          const errorMsg = error instanceof Error ? error.message : String(error);
          if (errors.length < 10) { // Limit error collection
            errors.push(errorMsg);
          }
        }
      });

      await Promise.all(batchPromises);
      completedRequests += requestsInBatch;
      
      process.stdout.write(`   Progress: ${completedRequests}/${options.totalRequests}\r`);
    }

    const totalTime = Date.now() - startTime;
    console.log(`   Progress: ${completedRequests}/${options.totalRequests} ✓`);

    // Calculate statistics
    responseTimes.sort((a, b) => a - b);
    const averageResponseTime = responseTimes.reduce((a, b) => a + b, 0) / responseTimes.length;
    const p95ResponseTime = responseTimes[Math.floor(responseTimes.length * 0.95)] || 0;
    const p99ResponseTime = responseTimes[Math.floor(responseTimes.length * 0.99)] || 0;
    const requestsPerSecond = (successfulRequests / totalTime) * 1000;

    const result: LoadTestResult = {
      scenario,
      concurrency: options.concurrency,
      totalRequests: options.totalRequests,
      successfulRequests,
      failedRequests,
      averageResponseTime,
      p95ResponseTime,
      p99ResponseTime,
      requestsPerSecond,
      errors: [...new Set(errors)].slice(0, 5) // Unique errors, max 5
    };

    this.loadTestResults.push(result);
    return result;
  }

  async runLoadTests(): Promise<void> {
    console.log("\n⚡ Load Testing");
    console.log("=".repeat(40));

    // Get test data
    const creatorsResult = await db.select().from(creators).limit(1);
    const creatorId = creatorsResult[0]?.id;
    
    if (!creatorId) {
      console.log("⚠️  No creators found, skipping load tests");
      return;
    }

    // Light load test - embedding generation
    await this.runLoadTest(
      "Embedding generation",
      () => embeddingService.generateEmbedding("test query for load testing"),
      { concurrency: 5, totalRequests: 25 }
    );

    // Medium load test - ad serving
    await this.runLoadTest(
      "Ad serving (contextual)",
      () => adServingService.serveContextualAds("cloud computing solutions", {
        creatorId,
        limit: 3,
        similarityThreshold: 0.25
      }),
      { concurrency: 3, totalRequests: 15 }
    );

    // Database load test
    await this.runLoadTest(
      "Database queries",
      () => db.select().from(ads).limit(5),
      { concurrency: 10, totalRequests: 50 }
    );
  }

  printBenchmarkReport(): void {
    console.log("\n" + "=".repeat(60));
    console.log("📊 PERFORMANCE BENCHMARK REPORT");
    console.log("=".repeat(60));

    // Benchmark results
    this.results.forEach(result => {
      console.log(`\n🔧 ${result.operation}:`);
      console.log(`   Iterations: ${result.iterations}`);
      console.log(`   Average: ${result.averageTime.toFixed(2)}ms`);
      console.log(`   Min/Max: ${result.minTime.toFixed(2)}ms / ${result.maxTime.toFixed(2)}ms`);
      console.log(`   Throughput: ${result.throughput.toFixed(2)} ops/sec`);
      if (result.memoryUsage) {
        console.log(`   Memory: ${result.memoryUsage.delta.toFixed(1)}MB delta`);
      }
    });

    // Load test results
    if (this.loadTestResults.length > 0) {
      console.log("\n⚡ LOAD TEST RESULTS:");
      this.loadTestResults.forEach(result => {
        console.log(`\n🔋 ${result.scenario}:`);
        console.log(`   Success Rate: ${((result.successfulRequests / result.totalRequests) * 100).toFixed(1)}%`);
        console.log(`   Average Response: ${result.averageResponseTime.toFixed(2)}ms`);
        console.log(`   P95/P99: ${result.p95ResponseTime}ms / ${result.p99ResponseTime}ms`);
        console.log(`   Throughput: ${result.requestsPerSecond.toFixed(2)} req/sec`);
        if (result.errors.length > 0) {
          console.log(`   Errors: ${result.errors.join(", ")}`);
        }
      });
    }

    // Performance recommendations
    console.log("\n💡 PERFORMANCE INSIGHTS:");
    
    const embeddingResult = this.results.find(r => r.operation.includes("embedding"));
    if (embeddingResult && embeddingResult.averageTime > 1000) {
      console.log("   ⚠️  Embedding generation is slow (>1s). Consider caching or batch processing.");
    }
    
    const searchResult = this.results.find(r => r.operation.includes("Vector search"));
    if (searchResult && searchResult.averageTime > 500) {
      console.log("   ⚠️  Vector search is slow (>500ms). Check database indexes and query optimization.");
    }
    
    const dbResult = this.results.find(r => r.operation.includes("Simple SELECT"));
    if (dbResult && dbResult.averageTime > 100) {
      console.log("   ⚠️  Database queries are slow (>100ms). Consider connection pooling or query optimization.");
    }
    
    console.log("   ✅ Run with larger datasets to get more accurate performance characteristics.");
    console.log("   ✅ Consider implementing caching for frequently accessed data.");
    console.log("   ✅ Monitor memory usage in production for potential leaks.");
  }

  async runFullBenchmark(): Promise<void> {
    console.log("🚀 Starting comprehensive performance benchmark\n");
    
    try {
      await this.benchmarkEmbeddings();
      await this.benchmarkVectorSearch();
      await this.benchmarkAdServing();
      await this.benchmarkDatabaseOperations();
      await this.runLoadTests();
      
      this.printBenchmarkReport();
      
    } catch (error) {
      console.error("💥 Benchmark failed:", error);
      process.exit(1);
    }
  }
}

// Run benchmark if this file is executed directly
if (require.main === module) {
  const benchmark = new PerformanceBenchmark();
  benchmark.runFullBenchmark();
}

export { PerformanceBenchmark };