import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { db } from "@/lib/db/connection";

export const auth = betterAuth({
  database: drizzleAdapter(db, {
    provider: "pg", 
  }),
  emailAndPassword: {
    enabled: true,
    requireEmailVerification: false,
  },
  session: {
    expiresIn: 60 * 60 * 24 * 7, // 7 days
    updateAge: 60 * 60 * 24, // 1 day (refresh session)
  },
  trustedOrigins: [
    "http://localhost:8000", 
    "http://localhost:8080",
    process.env.BETTER_AUTH_URL as string,
  ],
  secret: process.env.BETTER_AUTH_SECRET as string,
});