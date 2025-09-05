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
// Disable prepare for Railway compatibility
const client = postgres(connectionString, { 
  prepare: false,
  max: 1,
  connection: {
    application_name: "earnlayer-typescript"
  }
});
console.log("✅ Postgres client created");

console.log("🔧 Creating Drizzle instance...");
export const db = drizzle(client, { schema });
console.log("✅ Drizzle instance created");

export type Database = typeof db;