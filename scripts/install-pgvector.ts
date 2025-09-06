#!/usr/bin/env tsx

import { config } from "dotenv";
import { Client } from "pg";

// Load environment variables
if (process.env.NODE_ENV !== "production") {
  config({ path: ".env.local" });
}

async function installPgVector() {
  // Use Railway's pgvector database connection string
  const pgvectorUrl = "postgresql://postgres:TPyLaFqJiPjWEuIJzWCOJnecfvEuaQHf@postgres.railway.internal:5432/earnlayer";
  
  const client = new Client({
    connectionString: pgvectorUrl,
  });

  try {
    console.log("🔌 Connecting to pgvector database...");
    await client.connect();

    console.log("🧩 Installing pgvector extension...");
    await client.query("CREATE EXTENSION IF NOT EXISTS vector;");
    console.log("✅ pgvector extension installed successfully!");

    console.log("🔍 Checking extension status...");
    const result = await client.query(`
      SELECT extname, extversion 
      FROM pg_extension 
      WHERE extname = 'vector';
    `);
    
    if (result.rows.length > 0) {
      console.log(`✅ pgvector extension version: ${result.rows[0].extversion}`);
    } else {
      console.log("❌ pgvector extension not found");
    }

  } catch (error) {
    console.error("❌ Error installing pgvector extension:", error);
    process.exit(1);
  } finally {
    await client.end();
  }
}

installPgVector().catch(console.error);