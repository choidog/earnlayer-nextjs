import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { db } from "@/lib/db/connection";
import { user, account, session, verification, creators } from "@/lib/db/schema";
import crypto from "crypto";

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

// Helper function to generate unique creator name
function generateCreatorName(email: string, name?: string): string {
  if (name) {
    return `${name} (${email.split('@')[0]})`;
  }
  const emailPrefix = email.split('@')[0];
  const randomSuffix = crypto.randomBytes(3).toString('hex');
  return `Creator ${emailPrefix}_${randomSuffix}`;
}

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
    cookieCache: {
      enabled: true, // Re-enable cookie cache for same-domain setup
    },
  },
  advanced: {
    useSecureCookies: true,
    crossSubDomainCookies: {
      enabled: true, // Enable cross-subdomain cookies for same root domain
      domain: ".earnlayerai.com", // Share cookies between app.earnlayerai.com and api.earnlayerai.com
    },
    cookies: {
      session_token: {
        attributes: {
          sameSite: "lax", // Same root domain allows lax instead of none
          secure: true,
          httpOnly: true,
          domain: ".earnlayerai.com", // Share cookies across subdomains
        },
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
  hooks: {
    after: [
      {
        matcher(context) {
          return context.path?.startsWith("/sign-up") || false;
        },
        handler: async (ctx) => {
          try {
            console.log("🎯 [AUTH HOOK] User signed up:", ctx.user.email);
            
            // Create corresponding creator profile
            const creatorName = generateCreatorName(ctx.user.email, ctx.user.name);
            
            const creator = await db.insert(creators).values({
              userId: ctx.user.id,
              name: creatorName,
              email: ctx.user.email,
            }).returning();
            
            console.log("✅ [AUTH HOOK] Created creator:", {
              creatorId: creator[0].id,
              creatorName: creatorName,
              userId: ctx.user.id,
              email: ctx.user.email
            });
            
          } catch (error) {
            console.error("❌ [AUTH HOOK] Failed to create creator:", error);
            // Don't throw - we don't want to break the signup process
          }
        },
      },
    ],
  },
});
console.log("✅ Better Auth instance created successfully");