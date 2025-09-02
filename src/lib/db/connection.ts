import { drizzle } from "drizzle-orm/postgres-js";
import postgres from "postgres";
import * as schema from "./schema";
import { config } from "dotenv";

// Load environment variables
config({ path: ".env.local" });

const connectionString = process.env.DATABASE_URL;

if (!connectionString) {
  throw new Error("DATABASE_URL environment variable is not set");
}

console.log("Database URL:", connectionString);

// Disable prepare for Railway compatibility
const client = postgres(connectionString, { 
  prepare: false,
  max: 1,
  connection: {
    application_name: "earnlayer-typescript"
  }
});
export const db = drizzle(client, { schema });

export type Database = typeof db;