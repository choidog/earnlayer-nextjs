#!/usr/bin/env tsx
/**
 * Database Export Script
 * Exports data from Python FastAPI backend for migration
 */

import { config } from "dotenv";
import { Client } from "pg";
import fs from "fs/promises";
import path from "path";

// Load environment variables
config({ path: ".env.local" });

interface ExportStats {
  creators: number;
  campaigns: number;
  ads: number;
  sessions: number;
  messages: number;
  impressions: number;
  clicks: number;
  totalSizeKB: number;
}

class DatabaseExporter {
  private client: Client;
  private exportDir: string;
  private stats: ExportStats = {
    creators: 0,
    campaigns: 0,
    ads: 0,
    sessions: 0,
    messages: 0,
    impressions: 0,
    clicks: 0,
    totalSizeKB: 0
  };

  constructor(sourceUrl: string, exportDir = "./export") {
    this.client = new Client({
      connectionString: sourceUrl
    });
    this.exportDir = exportDir;
  }

  async connect() {
    console.log("🔌 Connecting to database...");
    await this.client.connect();
    console.log("✅ Connected to database");
    
    // Create export directory
    await fs.mkdir(this.exportDir, { recursive: true });
    console.log(`📁 Export directory: ${this.exportDir}`);
  }

  async disconnect() {
    await this.client.end();
    console.log("🔌 Disconnected from database");
  }

  async exportTable(tableName: string, query: string, filename: string) {
    console.log(`📊 Exporting ${tableName}...`);
    
    try {
      const result = await this.client.query(query);
      const data = {
        table: tableName,
        exportedAt: new Date().toISOString(),
        count: result.rows.length,
        rows: result.rows
      };

      const jsonData = JSON.stringify(data, null, 2);
      const filePath = path.join(this.exportDir, filename);
      await fs.writeFile(filePath, jsonData);

      const fileSize = Buffer.byteLength(jsonData, 'utf8') / 1024;
      this.stats.totalSizeKB += fileSize;

      console.log(`   ✅ Exported ${result.rows.length} rows (${fileSize.toFixed(1)}KB)`);
      return result.rows.length;
    } catch (error) {
      console.error(`   ❌ Failed to export ${tableName}:`, error);
      return 0;
    }
  }

  async exportCreators() {
    const count = await this.exportTable(
      "creators",
      `SELECT id, name, email, bio, created_at, updated_at, deleted_at
       FROM creators
       WHERE deleted_at IS NULL
       ORDER BY created_at`,
      "creators.json"
    );
    this.stats.creators = count;
  }

  async exportCampaigns() {
    const count = await this.exportTable(
      "ad_campaigns",
      `SELECT id, advertiser_id, name, start_date, end_date, 
              created_at, updated_at, deleted_at,
              budget_amount, spent_amount, currency, status, time_zone
       FROM ad_campaigns
       WHERE deleted_at IS NULL
       ORDER BY created_at`,
      "campaigns.json"
    );
    this.stats.campaigns = count;
  }

  async exportAds() {
    const count = await this.exportTable(
      "ads",
      `SELECT id, campaign_id, title, content, target_url,
              created_at, updated_at, deleted_at,
              ad_type, status, placement, pricing_model, bid_amount, currency,
              embedding
       FROM ads
       WHERE deleted_at IS NULL
       ORDER BY created_at`,
      "ads.json"
    );
    this.stats.ads = count;
  }

  async exportChatSessions() {
    const count = await this.exportTable(
      "chat_sessions",
      `SELECT id, creator_id, started_at, ended_at, metadata
       FROM chat_sessions
       ORDER BY started_at
       LIMIT 1000`,
      "chat_sessions.json"
    );
    this.stats.sessions = count;
  }

  async exportChatMessages() {
    const count = await this.exportTable(
      "chat_messages",
      `SELECT id, session_id, content, role, created_at, embedding
       FROM chat_messages
       ORDER BY created_at
       LIMIT 5000`,
      "chat_messages.json"
    );
    this.stats.messages = count;
  }

  async exportImpressions() {
    const count = await this.exportTable(
      "ad_impressions",
      `SELECT id, message_ad_id, ad_id, creator_id, created_at, updated_at,
              session_id, status, revenue_amount, creator_payout_amount, currency,
              impression_type, ad_queue_session_id, ad_queue_placement, mcp_tool_call_id
       FROM ad_impressions
       ORDER BY created_at
       LIMIT 10000`,
      "ad_impressions.json"
    );
    this.stats.impressions = count;
  }

  async exportClicks() {
    const count = await this.exportTable(
      "ad_clicks",
      `SELECT id, impression_id, click_metadata, created_at, is_billed
       FROM ad_clicks
       ORDER BY created_at
       LIMIT 10000`,
      "ad_clicks.json"
    );
    this.stats.clicks = count;
  }

  async exportSchema() {
    console.log("📋 Exporting database schema...");
    
    try {
      // Export table schemas
      const schemaResult = await this.client.query(`
        SELECT table_name, column_name, data_type, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public'
        ORDER BY table_name, ordinal_position
      `);

      // Export indexes
      const indexResult = await this.client.query(`
        SELECT schemaname, tablename, indexname, indexdef
        FROM pg_indexes
        WHERE schemaname = 'public'
        ORDER BY tablename, indexname
      `);

      const schemaData = {
        exportedAt: new Date().toISOString(),
        tables: schemaResult.rows,
        indexes: indexResult.rows
      };

      const jsonData = JSON.stringify(schemaData, null, 2);
      const filePath = path.join(this.exportDir, "schema.json");
      await fs.writeFile(filePath, jsonData);

      const fileSize = Buffer.byteLength(jsonData, 'utf8') / 1024;
      this.stats.totalSizeKB += fileSize;

      console.log(`   ✅ Schema exported (${fileSize.toFixed(1)}KB)`);
    } catch (error) {
      console.error("   ❌ Failed to export schema:", error);
    }
  }

  async runFullExport() {
    const startTime = Date.now();
    console.log("🚀 Starting database export...\n");

    try {
      await this.connect();

      // Export all tables
      await this.exportCreators();
      await this.exportCampaigns();
      await this.exportAds();
      await this.exportChatSessions();
      await this.exportChatMessages();
      await this.exportImpressions();
      await this.exportClicks();
      await this.exportSchema();

      // Generate summary
      const summaryData = {
        exportedAt: new Date().toISOString(),
        stats: this.stats,
        duration: (Date.now() - startTime) / 1000
      };

      const summaryPath = path.join(this.exportDir, "export_summary.json");
      await fs.writeFile(summaryPath, JSON.stringify(summaryData, null, 2));

      const endTime = Date.now();
      const duration = (endTime - startTime) / 1000;

      console.log("\n🎉 Export completed successfully!");
      console.log("📊 Export Statistics:");
      console.log(`   Creators: ${this.stats.creators}`);
      console.log(`   Campaigns: ${this.stats.campaigns}`);
      console.log(`   Ads: ${this.stats.ads}`);
      console.log(`   Chat Sessions: ${this.stats.sessions}`);
      console.log(`   Chat Messages: ${this.stats.messages}`);
      console.log(`   Ad Impressions: ${this.stats.impressions}`);
      console.log(`   Ad Clicks: ${this.stats.clicks}`);
      console.log(`   Total Size: ${this.stats.totalSizeKB.toFixed(1)}KB`);
      console.log(`   Duration: ${duration.toFixed(2)}s`);
      console.log(`   Export Directory: ${this.exportDir}`);

    } catch (error) {
      console.error("❌ Export failed:", error);
      throw error;
    } finally {
      await this.disconnect();
    }
  }
}

// CLI execution
async function main() {
  const sourceDbUrl = process.argv[2];
  const exportDir = process.argv[3] || "./export";
  
  if (!sourceDbUrl) {
    console.error("❌ Usage: npm run db:export <SOURCE_DATABASE_URL> [EXPORT_DIR]");
    console.error("   Example: npm run db:export 'postgresql://user:pass@localhost:5432/earnlayer_python' ./export");
    process.exit(1);
  }

  const exporter = new DatabaseExporter(sourceDbUrl, exportDir);
  
  try {
    await exporter.runFullExport();
    console.log("\n✅ Database export completed successfully!");
    console.log("   Next steps:");
    console.log(`   1. Copy exported data from '${exportDir}' to your TypeScript environment`);
    console.log("   2. Run 'npm run db:import <TARGET_DATABASE_URL>' to import the data");
    console.log("   3. Run 'npm run test:validate' to verify the import");
  } catch (error) {
    console.error("💥 Database export failed:", error);
    process.exit(1);
  }
}

// Run if called directly
if (require.main === module) {
  main();
}

export { DatabaseExporter };