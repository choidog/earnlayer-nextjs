import { defineConfig } from "drizzle-kit";
import { config } from "dotenv";

// Load environment variables only in development
if (process.env.NODE_ENV !== "production") {
  config({ path: ".env.local" });
}

export default defineConfig({
  schema: "./src/lib/db/schema.ts",
  out: "./drizzle/migrations",
  dialect: "postgresql",
  dbCredentials: {
    url: process.env.DATABASE_URL!,
  },
  verbose: true,
  strict: true,
  // Add connection configuration for better stability
  introspect: {
    casing: "snake_case"
  }
});