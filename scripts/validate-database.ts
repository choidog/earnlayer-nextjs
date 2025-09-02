import { db } from "../src/lib/db/connection";
import { creators, ads, adCampaigns, adImpressions, chatSessions, chatMessages } from "../src/lib/db/schema";
import { sql } from "drizzle-orm";
import { config } from "dotenv";

config({ path: ".env.local" });

interface ValidationResult {
  table: string;
  status: "pass" | "fail" | "warning";
  count: number;
  issues: string[];
  sampleData?: any[];
}

interface DatabaseValidation {
  status: "pass" | "fail" | "warning";
  totalTables: number;
  passedTables: number;
  results: ValidationResult[];
  summary: string;
}

export class DatabaseValidator {
  private results: ValidationResult[] = [];

  async validateTable(
    tableName: string,
    table: any,
    validations: {
      minCount?: number;
      maxCount?: number;
      requiredFields?: string[];
      customChecks?: Array<{ name: string; query: string; expected?: any }>;
    } = {}
  ): Promise<ValidationResult> {
    const result: ValidationResult = {
      table: tableName,
      status: "pass",
      count: 0,
      issues: [],
      sampleData: []
    };

    try {
      // Get row count
      const countResult = await db.select({ count: sql<number>`count(*)` }).from(table);
      result.count = countResult[0]?.count || 0;

      // Check minimum count
      if (validations.minCount && result.count < validations.minCount) {
        result.status = "fail";
        result.issues.push(`Expected at least ${validations.minCount} rows, found ${result.count}`);
      }

      // Check maximum count (warning only)
      if (validations.maxCount && result.count > validations.maxCount) {
        result.status = "warning";
        result.issues.push(`Found ${result.count} rows, expected max ${validations.maxCount}`);
      }

      // Get sample data (first 3 rows)
      if (result.count > 0) {
        const sampleResult = await db.select().from(table).limit(3);
        result.sampleData = sampleResult;

        // Check required fields in sample data
        if (validations.requiredFields && result.sampleData.length > 0) {
          const firstRow = result.sampleData[0];
          const missingFields = validations.requiredFields.filter(field => 
            firstRow[field] === null || firstRow[field] === undefined
          );
          
          if (missingFields.length > 0) {
            result.status = "warning";
            result.issues.push(`Missing or null required fields: ${missingFields.join(", ")}`);
          }
        }
      }

      // Run custom checks
      if (validations.customChecks) {
        for (const check of validations.customChecks) {
          try {
            const checkResult = await db.execute(sql.raw(check.query));
            const value = checkResult[0];
            
            if (check.expected !== undefined && value !== check.expected) {
              result.status = "warning";
              result.issues.push(`${check.name}: expected ${check.expected}, got ${value}`);
            }
          } catch (error) {
            result.status = "fail";
            result.issues.push(`${check.name} check failed: ${error}`);
          }
        }
      }

      console.log(`✅ ${tableName}: ${result.count} rows, ${result.issues.length} issues`);

    } catch (error) {
      result.status = "fail";
      result.issues.push(`Validation failed: ${error}`);
      console.error(`❌ ${tableName}: ${error}`);
    }

    this.results.push(result);
    return result;
  }

  async runFullValidation(): Promise<DatabaseValidation> {
    console.log("🔍 Running comprehensive database validation...\n");

    this.results = [];

    // Validate core tables with specific requirements
    await this.validateTable("creators", creators, {
      minCount: 1,
      requiredFields: ["id", "name", "email"],
      customChecks: [
        {
          name: "unique_emails",
          query: "SELECT COUNT(*) = COUNT(DISTINCT email) FROM creators WHERE deleted_at IS NULL"
        }
      ]
    });

    await this.validateTable("ad_campaigns", adCampaigns, {
      minCount: 1,
      requiredFields: ["id", "name", "budgetAmount", "spentAmount"],
      customChecks: [
        {
          name: "positive_budgets",
          query: "SELECT COUNT(*) FROM ad_campaigns WHERE budget_amount < 0"
        }
      ]
    });

    await this.validateTable("ads", ads, {
      minCount: 5, // Should have some ads for testing
      requiredFields: ["id", "title", "content", "campaignId"],
      customChecks: [
        {
          name: "active_ads",
          query: "SELECT COUNT(*) FROM ads WHERE status = 'active' AND deleted_at IS NULL"
        },
        {
          name: "ads_with_embeddings", 
          query: "SELECT COUNT(*) FROM ads WHERE embedding IS NOT NULL"
        }
      ]
    });

    await this.validateTable("chat_sessions", chatSessions, {
      requiredFields: ["id", "creatorId", "startedAt"]
    });

    await this.validateTable("chat_messages", chatMessages, {
      requiredFields: ["id", "sessionId", "content", "role"]
    });

    await this.validateTable("ad_impressions", adImpressions, {
      requiredFields: ["id", "adId", "creatorId"],
      customChecks: [
        {
          name: "valid_revenue_amounts",
          query: "SELECT COUNT(*) FROM ad_impressions WHERE CAST(revenue_amount AS DECIMAL) < 0"
        }
      ]
    });

    // Additional database health checks
    await this.validateDatabaseHealth();

    // Generate summary
    const passedTables = this.results.filter(r => r.status === "pass").length;
    const failedTables = this.results.filter(r => r.status === "fail").length;
    const warningTables = this.results.filter(r => r.status === "warning").length;

    const status = failedTables > 0 ? "fail" : warningTables > 0 ? "warning" : "pass";
    
    return {
      status,
      totalTables: this.results.length,
      passedTables,
      results: this.results,
      summary: `${passedTables} passed, ${failedTables} failed, ${warningTables} warnings`
    };
  }

  private async validateDatabaseHealth(): Promise<void> {
    console.log("🏥 Running database health checks...");

    try {
      // Check PostgreSQL version
      const versionResult = await db.execute(sql`SELECT version()`);
      console.log(`   PostgreSQL version: ${versionResult[0]?.version?.substring(0, 50)}...`);

      // Check pgvector extension
      const vectorCheck = await db.execute(
        sql`SELECT extname FROM pg_extension WHERE extname = 'vector'`
      );
      if (vectorCheck.length > 0) {
        console.log("   ✅ pgvector extension installed");
      } else {
        console.log("   ⚠️  pgvector extension not found");
      }

      // Check for foreign key constraints
      const fkCheck = await db.execute(sql`
        SELECT COUNT(*) as count 
        FROM information_schema.table_constraints 
        WHERE constraint_type = 'FOREIGN KEY'
      `);
      console.log(`   Foreign key constraints: ${fkCheck[0]?.count || 0}`);

      // Check for indexes
      const indexCheck = await db.execute(sql`
        SELECT COUNT(*) as count 
        FROM pg_indexes 
        WHERE schemaname = 'public'
      `);
      console.log(`   Indexes: ${indexCheck[0]?.count || 0}`);

    } catch (error) {
      console.error("   ❌ Health check failed:", error);
    }
  }

  printDetailedReport(validation: DatabaseValidation): void {
    console.log("\n📊 DATABASE VALIDATION REPORT");
    console.log("=" .repeat(50));
    console.log(`Overall Status: ${validation.status.toUpperCase()}`);
    console.log(`Summary: ${validation.summary}\n`);

    // Group results by status
    const failed = validation.results.filter(r => r.status === "fail");
    const warnings = validation.results.filter(r => r.status === "warning");
    const passed = validation.results.filter(r => r.status === "pass");

    if (failed.length > 0) {
      console.log("❌ FAILED TABLES:");
      failed.forEach(result => {
        console.log(`   ${result.table} (${result.count} rows)`);
        result.issues.forEach(issue => console.log(`     • ${issue}`));
      });
      console.log("");
    }

    if (warnings.length > 0) {
      console.log("⚠️  TABLES WITH WARNINGS:");
      warnings.forEach(result => {
        console.log(`   ${result.table} (${result.count} rows)`);
        result.issues.forEach(issue => console.log(`     • ${issue}`));
      });
      console.log("");
    }

    if (passed.length > 0) {
      console.log("✅ HEALTHY TABLES:");
      passed.forEach(result => {
        console.log(`   ${result.table}: ${result.count} rows`);
      });
      console.log("");
    }

    // Sample data preview
    console.log("📋 SAMPLE DATA PREVIEW:");
    validation.results.slice(0, 3).forEach(result => {
      if (result.sampleData && result.sampleData.length > 0) {
        console.log(`\n${result.table.toUpperCase()} (first row):`);
        const sample = result.sampleData[0];
        Object.keys(sample).slice(0, 5).forEach(key => {
          const value = sample[key];
          const displayValue = typeof value === 'string' && value.length > 50 
            ? value.substring(0, 50) + "..." 
            : value;
          console.log(`   ${key}: ${displayValue}`);
        });
      }
    });
  }
}

async function runValidation() {
  const validator = new DatabaseValidator();
  
  try {
    const result = await validator.runFullValidation();
    validator.printDetailedReport(result);
    
    if (result.status === "fail") {
      console.log("\n🚨 CRITICAL ISSUES FOUND");
      console.log("Please fix failed validations before proceeding.");
      process.exit(1);
    } else if (result.status === "warning") {
      console.log("\n⚠️  WARNINGS DETECTED");
      console.log("Consider reviewing warnings, but system should work.");
    } else {
      console.log("\n🎉 ALL VALIDATIONS PASSED");
      console.log("Database is ready for testing!");
    }
    
  } catch (error) {
    console.error("💥 Validation failed:", error);
    process.exit(1);
  }
}

// Run validation if this file is executed directly
if (require.main === module) {
  runValidation();
}

export { DatabaseValidator };