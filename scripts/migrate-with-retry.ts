#!/usr/bin/env tsx

import { drizzle } from "drizzle-orm/postgres-js";
import { migrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";
import { config } from "dotenv";
import { execSync } from "child_process";

// Load environment variables
if (process.env.NODE_ENV !== "production") {
  config({ path: ".env.local" });
}

let connectionString = process.env.DATABASE_URL;

if (!connectionString) {
  console.error("❌ DATABASE_URL environment variable is not set");
  process.exit(1);
}

// Railway Private Networking: Try to use internal networking if we're on Railway
function tryPrivateNetworking(publicUrl: string): string {
  try {
    const url = new URL(publicUrl);

    // Check if this is a Railway proxy URL
    if (url.hostname.includes('.proxy.rlwy.net')) {
      console.log("🔍 Detected Railway proxy URL, attempting private networking...");

      // Extract credentials and database name
      const username = url.username;
      const password = url.password;
      const database = url.pathname.slice(1) || 'railway';

      // Construct private networking URL
      const privateUrl = `postgres://${username}:${password}@postgres.railway.internal:5432/${database}`;

      console.log("🔧 Private URL constructed:");
      console.log(`   Original: ${url.hostname}:${url.port}`);
      console.log(`   Private:  postgres.railway.internal:5432`);

      return privateUrl;
    }

    console.log("ℹ️ Not a Railway proxy URL, using original connection string");
    return publicUrl;
  } catch (error) {
    console.error("⚠️ Error parsing URL for private networking, using original:", error);
    return publicUrl;
  }
}

// Try to use private networking
const originalConnectionString = connectionString;
connectionString = tryPrivateNetworking(connectionString);

console.log("🌐 Database Connection Strategy:");
console.log(`   Using: ${connectionString.includes('railway.internal') ? 'Private Networking' : 'Public Proxy'}`);
console.log(`   DNS Delay: ${connectionString.includes('railway.internal') ? 'Required (3s)' : 'Not needed'}`);

// Railway DNS workaround function
async function applyRailwayDnsWorkaround() {
  if (connectionString.includes('railway.internal')) {
    console.log("⏳ Applying Railway private network DNS workaround (3 second delay)...");
    await new Promise(resolve => setTimeout(resolve, 3000));
    console.log("✅ DNS workaround delay completed");
  }
}

// Enhanced debugging function
async function debugEnvironment() {
  console.log("\n🔍 === RAILWAY ENVIRONMENT DEBUG ===");
  console.log(`⏰ Timestamp: ${new Date().toISOString()}`);
  console.log(`🔢 Process PID: ${process.pid}`);
  console.log(`💾 Memory Usage: ${Math.round(process.memoryUsage().heapUsed / 1024 / 1024)}MB`);
  console.log(`⚡ Node Version: ${process.version}`);
  console.log(`🏗️ Platform: ${process.platform} ${process.arch}`);

  // Railway-specific environment
  console.log(`🚂 Railway Project: ${process.env.RAILWAY_PROJECT_NAME || 'undefined'}`);
  console.log(`🌍 Railway Environment: ${process.env.RAILWAY_ENVIRONMENT || 'undefined'}`);
  console.log(`🔧 Railway Service: ${process.env.RAILWAY_SERVICE_NAME || 'undefined'}`);
  console.log(`🌐 Railway Public Domain: ${process.env.RAILWAY_PUBLIC_DOMAIN || 'undefined'}`);

  // Parse and analyze DATABASE_URL
  try {
    const dbUrl = new URL(connectionString);
    console.log(`\n📊 === DATABASE CONNECTION ANALYSIS ===`);
    console.log(`🎯 Protocol: ${dbUrl.protocol}`);
    console.log(`🌐 Hostname: ${dbUrl.hostname}`);
    console.log(`🔌 Port: ${dbUrl.port}`);
    console.log(`📂 Database: ${dbUrl.pathname.slice(1)}`);
    console.log(`👤 Username: ${dbUrl.username}`);
    console.log(`🔐 Password: ${dbUrl.password ? `${dbUrl.password.substring(0, 3)}***` : 'undefined'}`);

    // Network connectivity tests
    console.log(`\n🌐 === NETWORK CONNECTIVITY TESTS ===`);

    // Test 1: DNS Resolution
    try {
      console.log(`🔍 Testing DNS resolution for ${dbUrl.hostname}...`);
      const dnsResult = execSync(`nslookup ${dbUrl.hostname}`, { encoding: 'utf8', timeout: 10000 });
      console.log(`✅ DNS Resolution successful`);
      console.log(`📝 DNS Response:\n${dnsResult}`);
    } catch (dnsError: any) {
      console.error(`❌ DNS Resolution failed: ${dnsError.message}`);
    }

    // Test 2: Port connectivity
    try {
      console.log(`🔌 Testing port connectivity to ${dbUrl.hostname}:${dbUrl.port}...`);
      const portResult = execSync(`timeout 10 bash -c "</dev/tcp/${dbUrl.hostname}/${dbUrl.port}"`, {
        encoding: 'utf8',
        timeout: 15000
      });
      console.log(`✅ Port ${dbUrl.port} is reachable`);
    } catch (portError: any) {
      console.error(`❌ Port connectivity failed: ${portError.message}`);
      console.error(`💡 This suggests Railway proxy may be down or unreachable`);
    }

    // Test 3: Basic network tools
    try {
      console.log(`\n🛠️ === NETWORK TOOLS ANALYSIS ===`);
      const pingResult = execSync(`ping -c 3 ${dbUrl.hostname}`, { encoding: 'utf8', timeout: 10000 });
      console.log(`🏓 Ping test:\n${pingResult}`);
    } catch (pingError: any) {
      console.error(`❌ Ping failed: ${pingError.message}`);
    }

  } catch (urlError: any) {
    console.error(`❌ Invalid DATABASE_URL format: ${urlError.message}`);
  }

  console.log(`\n⏱️ === TIMING ANALYSIS ===`);
  console.log(`🕐 Container started: ${process.uptime()}s ago`);
  console.log(`📅 Current time: ${new Date().toISOString()}`);
}

async function runMigrationWithRetry(maxRetries = 3, delay = 5000) {
  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    console.log(`\n🔧 === MIGRATION ATTEMPT ${attempt}/${maxRetries} ===`);
    console.log(`⏰ Attempt started at: ${new Date().toISOString()}`);

    // Create a new connection for each attempt with enhanced debugging
    console.log(`🔌 Creating PostgreSQL connection...`);

    const startTime = Date.now();
    const client = postgres(connectionString, {
      prepare: false,
      max: 1, // Single connection for migration
      idle_timeout: 60,
      connect_timeout: 30,
      connection: {
        application_name: "earnlayer-migration-debug",
        statement_timeout: 60000,
        query_timeout: 60000
      },
      onnotice: (notice) => {
        console.log(`🔔 DB Notice [${Date.now() - startTime}ms]:`, notice.message);
      },
      onparameter: (key, value) => {
        console.log(`🔧 DB Parameter [${Date.now() - startTime}ms]: ${key}=${value}`);
      },
      debug: (connection, query, parameters) => {
        console.log(`🐛 DB Debug [${Date.now() - startTime}ms]: Connection ${connection} executing query: ${query.slice(0, 200)}${query.length > 200 ? '...' : ''}`);
        if (parameters && parameters.length > 0) {
          console.log(`📝 Query parameters: ${JSON.stringify(parameters)}`);
        }
      },
      transform: {
        undefined: null
      }
    });

    const db = drizzle(client);

    try {
      console.log(`📦 Running database migrations [${Date.now() - startTime}ms]...`);

      // Connection test first
      console.log(`🧪 Testing basic connection [${Date.now() - startTime}ms]...`);
      try {
        const testResult = await client`SELECT NOW() as current_time, version() as db_version`;
        console.log(`✅ Connection test successful [${Date.now() - startTime}ms]:`);
        console.log(`   🕐 Database time: ${testResult[0]?.current_time}`);
        console.log(`   📊 Database version: ${testResult[0]?.db_version}`);
      } catch (testError: any) {
        console.error(`❌ Connection test failed [${Date.now() - startTime}ms]:`, testError);
        throw testError;
      }

      // Check existing schemas
      console.log(`🔍 Checking existing schemas [${Date.now() - startTime}ms]...`);
      try {
        const schemas = await client`SELECT schema_name FROM information_schema.schemata ORDER BY schema_name`;
        console.log(`📋 Existing schemas [${Date.now() - startTime}ms]:`, schemas.map(s => s.schema_name));
      } catch (schemaListError: any) {
        console.error(`⚠️ Could not list schemas [${Date.now() - startTime}ms]:`, schemaListError.message);
      }

      // First, try to create the drizzle schema manually
      console.log(`🏗️ Creating drizzle schema [${Date.now() - startTime}ms]...`);
      try {
        await client`CREATE SCHEMA IF NOT EXISTS drizzle`;
        console.log(`✅ Drizzle schema created successfully [${Date.now() - startTime}ms]`);
      } catch (schemaError: any) {
        console.error(`❌ Schema creation error [${Date.now() - startTime}ms]:`, {
          message: schemaError.message,
          code: schemaError.code,
          detail: schemaError.detail,
          hint: schemaError.hint,
          position: schemaError.position,
          internalQuery: schemaError.internalQuery,
          where: schemaError.where,
          file: schemaError.file,
          line: schemaError.line,
          routine: schemaError.routine
        });

        if (schemaError.code !== '42P06') { // Schema already exists
          throw schemaError;
        } else {
          console.log(`ℹ️ Schema already exists [${Date.now() - startTime}ms]`);
        }
      }

      // Run the migrations
      console.log(`🚀 Starting migration execution [${Date.now() - startTime}ms]...`);
      await migrate(db, { migrationsFolder: "./drizzle/migrations" });
      console.log(`✅ Database migrations completed successfully [${Date.now() - startTime}ms]!`);

      // Close the connection
      console.log(`🔌 Closing connection [${Date.now() - startTime}ms]...`);
      await client.end();
      console.log(`✅ Connection closed successfully [${Date.now() - startTime}ms]`);
      return true;

    } catch (error: any) {
      const errorTime = Date.now() - startTime;
      console.error(`\n❌ === MIGRATION FAILURE ANALYSIS [${errorTime}ms] ===`);
      console.error(`🚨 Error Type: ${error.constructor.name}`);
      console.error(`📝 Error Message: ${error.message}`);
      console.error(`🔢 Error Code: ${error.code || 'undefined'}`);
      console.error(`📍 Error Detail: ${error.detail || 'undefined'}`);
      console.error(`💡 Error Hint: ${error.hint || 'undefined'}`);

      if (error.cause) {
        console.error(`🔗 Root Cause: ${error.cause.message || error.cause}`);
        console.error(`🏷️ Cause Code: ${error.cause.code || 'undefined'}`);
        console.error(`🌐 Cause Address: ${error.cause.address || 'undefined'}`);
        console.error(`🔌 Cause Port: ${error.cause.port || 'undefined'}`);
      }

      if (error.stack) {
        console.error(`📚 Stack Trace (first 10 lines):`);
        error.stack.split('\n').slice(0, 10).forEach((line: string, i: number) => {
          console.error(`   ${i + 1}: ${line}`);
        });
      }

      // Close the connection on error
      try {
        console.log(`🔌 Attempting to close connection after error [${errorTime}ms]...`);
        await client.end();
        console.log(`✅ Connection closed after error [${Date.now() - startTime}ms]`);
      } catch (closeError: any) {
        console.error(`❌ Error closing connection [${Date.now() - startTime}ms]:`, closeError.message);
      }

      if (attempt === maxRetries) {
        console.error(`\n💥 === ALL MIGRATION ATTEMPTS EXHAUSTED ===`);
        console.error(`🔢 Total attempts: ${maxRetries}`);
        console.error(`⏱️ Total duration: ${Date.now() - startTime}ms`);
        throw error;
      }

      console.log(`\n⏳ === RETRY DELAY [${errorTime}ms] ===`);
      console.log(`⏰ Waiting ${delay}ms before retry ${attempt + 1}/${maxRetries}...`);
      console.log(`🕐 Next attempt at: ${new Date(Date.now() + delay).toISOString()}`);
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }

  return false;
}

// Main execution
async function main() {
  console.log('🚀 === MIGRATION PROCESS STARTING ===');
  console.log(`⏰ Start time: ${new Date().toISOString()}`);

  // Run comprehensive environment debugging
  await debugEnvironment();

  // Apply Railway DNS workaround if using private networking
  await applyRailwayDnsWorkaround();

  // Attempt migrations with retry logic
  console.log('\n🔄 === STARTING MIGRATION ATTEMPTS ===');
  try {
    await runMigrationWithRetry();
    console.log('\n🎉 === MIGRATION PROCESS COMPLETED SUCCESSFULLY ===');
    console.log(`⏰ End time: ${new Date().toISOString()}`);
    process.exit(0);
  } catch (error: any) {
    console.error('\n💥 === MIGRATION PROCESS FAILED ===');
    console.error(`⏰ Failure time: ${new Date().toISOString()}`);
    console.error('🚨 Final error:', error.message);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error('💥 === CRITICAL ERROR IN MAIN ===');
  console.error(error);
  process.exit(1);
});