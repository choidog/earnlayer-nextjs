import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { db } from "@/lib/db/connection";
import { user, account, session, verification } from "@/lib/db/schema";

console.log("🔧 Better Auth Config - Loading...");
console.log("🔧 Environment variables:");
console.log("  - BETTER_AUTH_SECRET:", process.env.BETTER_AUTH_SECRET ? "***SET***" : "MISSING");
console.log("  - BETTER_AUTH_URL:", process.env.BETTER_AUTH_URL);
console.log("  - GOOGLE_CLIENT_ID:", process.env.GOOGLE_CLIENT_ID ? "***SET***" : "MISSING");
console.log("  - GOOGLE_CLIENT_SECRET:", process.env.GOOGLE_CLIENT_SECRET ? "***SET***" : "MISSING");
console.log("  - NODE_ENV:", process.env.NODE_ENV);

console.log("🔧 Creating drizzle adapter...");
const adapter = drizzleAdapter(db, {
  provider: "pg",
  schema: {
    user: user,
    account: account, 
    session: session,
    verification: verification, // Use Better Auth verification table
  },
});
console.log("✅ Drizzle adapter created successfully");

console.log("🔧 Creating Better Auth instance...");
export const auth = betterAuth({
  database: adapter,
  emailAndPassword: {
    enabled: true,
    requireEmailVerification: false,
  },
  socialProviders: {
    google: {
      clientId: process.env.GOOGLE_CLIENT_ID as string,
      clientSecret: process.env.GOOGLE_CLIENT_SECRET as string,
    },
  },
  session: {
    expiresIn: 60 * 60 * 24 * 7, // 7 days
    updateAge: 60 * 60 * 24, // 1 day (refresh session)
  },
  cookies: {
    sessionToken: {
      name: "better-auth.session_token",
      options: {
        httpOnly: true,
        secure: true,
        sameSite: "none", // Allow cross-site cookies
      },
    },
  },
  trustedOrigins: [
    "http://localhost:8000", 
    "http://localhost:8080",
    process.env.BETTER_AUTH_URL as string,
    process.env.FRONTEND_DOMAIN as string,
    `${process.env.FRONTEND_DOMAIN}/dashboard`,
  ].filter(Boolean),
  secret: process.env.BETTER_AUTH_SECRET as string,
});
console.log("✅ Better Auth instance created successfully");