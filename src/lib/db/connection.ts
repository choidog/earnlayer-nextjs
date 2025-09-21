import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";
import { config } from "dotenv";

console.log("🔧 DB Connection - Starting...");
console.log("🔧 NODE_ENV:", process.env.NODE_ENV);

// Load environment variables only in development
if (process.env.NODE_ENV !== "production") {
  console.log("🔧 Loading .env.local for development");
  config({ path: ".env.local" });
} else {
  console.log("🔧 Production mode - using Railway environment variables");
}

const connectionString = process.env.DATABASE_URL;

if (!connectionString) {
  console.error("❌ DATABASE_URL environment variable is not set");
  throw new Error("DATABASE_URL environment variable is not set");
}

console.log("🔧 Database URL:", connectionString);

console.log("🔧 Creating postgres client...");
// Enhanced connection configuration for Railway compatibility
const client = postgres(connectionString, {
  prepare: false,
  max: 10, // Increased pool size for better connection handling
  idle_timeout: 120, // Increased for Railway proxy
  max_lifetime: 60 * 30, // 30 minutes
  connect_timeout: 60, // Increased to match working migration script
  socket_timeout: 120, // Add socket timeout like migration script
  // Add retry logic for connection resets
  connection: {
    application_name: "earnlayer-typescript",
    statement_timeout: 120000, // Increased to match working migration script
    tcp_keepalives_idle: 30,
    tcp_keepalives_interval: 10,
    tcp_keepalives_count: 3
  },
  // Handle connection errors gracefully
  onnotice: (notice) => console.log('🔔 DB Notice:', notice),
  transform: {
    undefined: null
  }
});
console.log("✅ Postgres client created");

console.log("🔧 Creating Drizzle instance...");
export const db = drizzle(client, { schema });
console.log("✅ Drizzle instance created");

export type Database = typeof db;