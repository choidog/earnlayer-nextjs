#!/usr/bin/env tsx

import { drizzle } from "drizzle-orm/postgres-js";
import { migrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";
import { config } from "dotenv";

// Load environment variables
if (process.env.NODE_ENV !== "production") {
  config({ path: ".env.local" });
}

const connectionString = process.env.DATABASE_URL;

if (!connectionString) {
  console.error("❌ DATABASE_URL environment variable is not set");
  process.exit(1);
}

async function runMigrationWithRetry(maxRetries = 3, delay = 5000) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    console.log(`🔧 Migration attempt ${attempt}/${maxRetries}...`);

    // Create a new connection for each attempt
    const client = postgres(connectionString, {
      prepare: false,
      max: 1, // Single connection for migration
      idle_timeout: 60,
      connect_timeout: 30,
      connection: {
        application_name: "earnlayer-migration",
        statement_timeout: 60000,
        query_timeout: 60000
      },
      onnotice: (notice) => console.log('🔔 DB Notice:', notice),
      transform: {
        undefined: null
      }
    });

    const db = drizzle(client);

    try {
      console.log('📦 Running database migrations...');

      // First, try to create the drizzle schema manually
      try {
        await client`CREATE SCHEMA IF NOT EXISTS drizzle`;
        console.log('✅ Drizzle schema created successfully');
      } catch (schemaError: any) {
        if (schemaError.code !== '42P06') { // Schema already exists
          console.log('⚠️ Schema creation warning:', schemaError.message);
        }
      }

      // Run the migrations
      await migrate(db, { migrationsFolder: "./drizzle/migrations" });
      console.log('✅ Database migrations completed successfully!');

      // Close the connection
      await client.end();
      return true;

    } catch (error: any) {
      console.error(`❌ Migration attempt ${attempt} failed:`, error.message);

      // Close the connection on error
      try {
        await client.end();
      } catch (closeError) {
        console.log('⚠️ Error closing connection:', closeError);
      }

      if (attempt === maxRetries) {
        console.error(`💥 All ${maxRetries} migration attempts failed`);
        throw error;
      }

      console.log(`⏳ Waiting ${delay}ms before retry...`);
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }

  return false;
}

// Main execution
runMigrationWithRetry()
  .then(() => {
    console.log('🎉 Migration process completed successfully');
    process.exit(0);
  })
  .catch((error) => {
    console.error('💥 Migration process failed:', error);
    process.exit(1);
  });