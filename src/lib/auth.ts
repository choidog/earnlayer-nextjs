import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";

let _auth: any = null;

export const auth = {
  get handler() {
    if (!_auth) {
      const { db } = require("@/lib/db/connection");
      _auth = betterAuth({
        database: drizzleAdapter(db, {
          provider: "pg",
        }),
        emailAndPassword: {
          enabled: false,
        },
        socialProviders: {
          google: {
            clientId: process.env.GOOGLE_CLIENT_ID as string,
            clientSecret: process.env.GOOGLE_CLIENT_SECRET as string,
          },
        },
        baseURL: process.env.BETTER_AUTH_URL || "https://api.earnlayerai.com",
      });
    }
    return _auth.handler;
  }
};