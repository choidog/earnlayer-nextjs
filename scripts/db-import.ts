#!/usr/bin/env tsx
/**
 * Database Import Script
 * Migrates data from Python FastAPI backend to TypeScript Next.js backend
 */

import { config } from "dotenv";
import { Client } from "pg";
import { db } from "../src/lib/db/connection";
import { 
  creators, 
  adCampaigns, 
  ads, 
  chatSessions, 
  chatMessages,
  adImpressions,
  adClicks
} from "../src/lib/db/schema";

// Load environment variables
config({ path: ".env.local" });

interface ImportStats {
  creators: number;
  campaigns: number;
  ads: number;
  sessions: number;
  messages: number;
  impressions: number;
  clicks: number;
}

class DatabaseImporter {
  private sourceClient: Client;
  private targetDb = db;
  private stats: ImportStats = {
    creators: 0,
    campaigns: 0,
    ads: 0,
    sessions: 0,
    messages: 0,
    impressions: 0,
    clicks: 0
  };

  constructor(sourceUrl: string) {
    this.sourceClient = new Client({
      connectionString: sourceUrl
    });
  }

  async connect() {
    console.log("🔌 Connecting to source database...");
    await this.sourceClient.connect();
    console.log("✅ Connected to source database");
    
    console.log("🔌 Testing target database connection...");
    await this.targetDb.select().from(creators).limit(1);
    console.log("✅ Connected to target database");
  }

  async disconnect() {
    await this.sourceClient.end();
    console.log("🔌 Disconnected from source database");
  }

  async importCreators() {
    console.log("\n👤 Importing creators...");
    
    const result = await this.sourceClient.query(`
      SELECT id, user_id, name, bio, created_at, updated_at
      FROM creators
      WHERE is_active = true
      ORDER BY created_at
    `);

    if (result.rows.length === 0) {
      console.log("   No creators found in source database");
      return;
    }

    for (const row of result.rows) {
      await this.targetDb.insert(creators)
        .values({
          id: row.id,
          name: row.name,
          email: `creator_${row.user_id}@earnlayer.app`, // Generate email from user_id
          bio: row.bio,
          createdAt: row.created_at,
          updatedAt: row.updated_at,
          deletedAt: null
        })
        .onConflictDoNothing();
      
      this.stats.creators++;
    }

    console.log(`   ✅ Imported ${this.stats.creators} creators`);
  }

  async importCampaigns() {
    console.log("\n📈 Importing campaigns...");
    
    const result = await this.sourceClient.query(`
      SELECT id, advertiser_id, name, start_date, end_date, 
             created_at, updated_at, deleted_at,
             budget_amount, spent_amount, currency, status, time_zone
      FROM ad_campaigns
      WHERE deleted_at IS NULL
      ORDER BY created_at
    `);

    if (result.rows.length === 0) {
      console.log("   No campaigns found in source database");
      return;
    }

    for (const row of result.rows) {
      await this.targetDb.insert(adCampaigns)
        .values({
          id: row.id,
          advertiserId: row.advertiser_id,
          name: row.name,
          startDate: row.start_date,
          endDate: row.end_date,
          createdAt: row.created_at,
          updatedAt: row.updated_at,
          deletedAt: row.deleted_at,
          budgetAmount: row.budget_amount.toString(),
          spentAmount: row.spent_amount.toString(),
          currency: row.currency,
          status: row.status,
          timeZone: row.time_zone
        })
        .onConflictDoNothing();
      
      this.stats.campaigns++;
    }

    console.log(`   ✅ Imported ${this.stats.campaigns} campaigns`);
  }

  async importAds() {
    console.log("\n📢 Importing ads...");
    
    const result = await this.sourceClient.query(`
      SELECT id, campaign_id, title, description, url,
             created_at, updated_at, deleted_at,
             ad_type, status, pricing_model, image_url
      FROM ads
      WHERE deleted_at IS NULL
      ORDER BY created_at
    `);

    if (result.rows.length === 0) {
      console.log("   No ads found in source database");
      return;
    }

    for (const row of result.rows) {
      await this.targetDb.insert(ads)
        .values({
          id: row.id,
          campaignId: row.campaign_id,
          title: row.title,
          content: row.description || row.title, // Use description as content
          targetUrl: row.url,
          createdAt: row.created_at,
          updatedAt: row.updated_at,
          deletedAt: row.deleted_at,
          adType: row.ad_type,
          status: row.status,
          placement: "default", // Default placement since not in source
          pricingModel: row.pricing_model,
          bidAmount: null, // Not in source schema
          currency: "USD", // Default currency
          embedding: null // Will be generated later
        })
        .onConflictDoNothing();
      
      this.stats.ads++;
    }

    console.log(`   ✅ Imported ${this.stats.ads} ads`);
  }

  async importChatSessions() {
    console.log("\n💬 Importing chat sessions...");
    
    const result = await this.sourceClient.query(`
      SELECT id, creator_id, started_at, ended_at, metadata
      FROM chat_sessions
      ORDER BY started_at
      LIMIT 1000
    `);

    if (result.rows.length === 0) {
      console.log("   No chat sessions found in source database");
      return;
    }

    for (const row of result.rows) {
      await this.targetDb.insert(chatSessions)
        .values({
          id: row.id,
          creatorId: row.creator_id,
          startedAt: row.started_at,
          endedAt: row.ended_at,
          metadata: row.metadata
        })
        .onConflictDoNothing();
      
      this.stats.sessions++;
    }

    console.log(`   ✅ Imported ${this.stats.sessions} chat sessions`);
  }

  async importChatMessages() {
    console.log("\n💬 Importing chat messages...");
    
    const result = await this.sourceClient.query(`
      SELECT id, session_id, content, role, created_at, embedding
      FROM chat_messages
      ORDER BY created_at
      LIMIT 5000
    `);

    if (result.rows.length === 0) {
      console.log("   No chat messages found in source database");
      return;
    }

    for (const row of result.rows) {
      await this.targetDb.insert(chatMessages)
        .values({
          id: row.id,
          sessionId: row.session_id,
          content: row.content,
          role: row.role,
          createdAt: row.created_at,
          embedding: row.embedding ? `[${row.embedding.join(",")}]` : null
        })
        .onConflictDoNothing();
      
      this.stats.messages++;
    }

    console.log(`   ✅ Imported ${this.stats.messages} chat messages`);
  }

  async importImpressions() {
    console.log("\n📊 Importing ad impressions...");
    
    const result = await this.sourceClient.query(`
      SELECT id, message_ad_id, ad_id, creator_id, created_at, updated_at,
             session_id, status, revenue_amount, creator_payout_amount, currency,
             impression_type, ad_queue_session_id, ad_queue_placement, mcp_tool_call_id
      FROM ad_impressions
      ORDER BY created_at
      LIMIT 10000
    `);

    if (result.rows.length === 0) {
      console.log("   No ad impressions found in source database");
      return;
    }

    for (const row of result.rows) {
      await this.targetDb.insert(adImpressions)
        .values({
          id: row.id,
          messageAdId: row.message_ad_id,
          adId: row.ad_id,
          creatorId: row.creator_id,
          createdAt: row.created_at,
          updatedAt: row.updated_at,
          sessionId: row.session_id,
          status: row.status,
          revenueAmount: row.revenue_amount.toString(),
          creatorPayoutAmount: row.creator_payout_amount.toString(),
          currency: row.currency,
          impressionType: row.impression_type,
          adQueueSessionId: row.ad_queue_session_id,
          adQueuePlacement: row.ad_queue_placement,
          mcpToolCallId: row.mcp_tool_call_id
        })
        .onConflictDoNothing();
      
      this.stats.impressions++;
    }

    console.log(`   ✅ Imported ${this.stats.impressions} ad impressions`);
  }

  async importClicks() {
    console.log("\n🖱️ Importing ad clicks...");
    
    const result = await this.sourceClient.query(`
      SELECT id, impression_id, click_metadata, created_at, is_billed
      FROM ad_clicks
      ORDER BY created_at
      LIMIT 10000
    `);

    if (result.rows.length === 0) {
      console.log("   No ad clicks found in source database");
      return;
    }

    for (const row of result.rows) {
      await this.targetDb.insert(adClicks)
        .values({
          id: row.id,
          impressionId: row.impression_id,
          clickMetadata: row.click_metadata,
          createdAt: row.created_at,
          isBilled: row.is_billed
        })
        .onConflictDoNothing();
      
      this.stats.clicks++;
    }

    console.log(`   ✅ Imported ${this.stats.clicks} ad clicks`);
  }

  async runFullImport() {
    const startTime = Date.now();
    console.log("🚀 Starting database import...\n");

    try {
      await this.connect();

      // Import in dependency order - only core tables that exist
      await this.importCreators();
      await this.importCampaigns();
      await this.importAds();

      const endTime = Date.now();
      const duration = (endTime - startTime) / 1000;

      console.log("\n🎉 Import completed successfully!");
      console.log("📊 Import Statistics:");
      console.log(`   Creators: ${this.stats.creators}`);
      console.log(`   Campaigns: ${this.stats.campaigns}`);
      console.log(`   Ads: ${this.stats.ads}`);
      console.log(`   Chat Sessions: ${this.stats.sessions}`);
      console.log(`   Chat Messages: ${this.stats.messages}`);
      console.log(`   Ad Impressions: ${this.stats.impressions}`);
      console.log(`   Ad Clicks: ${this.stats.clicks}`);
      console.log(`   Total Duration: ${duration.toFixed(2)}s`);

    } catch (error) {
      console.error("❌ Import failed:", error);
      throw error;
    } finally {
      await this.disconnect();
    }
  }
}

// CLI execution
async function main() {
  const sourceDbUrl = process.argv[2];
  
  if (!sourceDbUrl) {
    console.error("❌ Usage: npm run db:import <SOURCE_DATABASE_URL>");
    console.error("   Example: npm run db:import 'postgresql://user:pass@localhost:5432/earnlayer_python'");
    process.exit(1);
  }

  const importer = new DatabaseImporter(sourceDbUrl);
  
  try {
    await importer.runFullImport();
    console.log("\n✅ Database migration completed successfully!");
    console.log("   Next steps:");
    console.log("   1. Run 'npm run test:validate' to verify data integrity");
    console.log("   2. Run 'npm run test:comprehensive' to test full functionality");
    console.log("   3. Run 'npm run test:benchmark' to compare performance");
  } catch (error) {
    console.error("💥 Database migration failed:", error);
    process.exit(1);
  }
}

// Run if called directly
if (require.main === module) {
  main();
}

export { DatabaseImporter };