import {
  pgTable,
  uuid,
  text,
  timestamp,
  varchar,
  numeric,
  boolean,
  jsonb,
  pgEnum,
  char,
  serial,
  integer,
  unique,
  decimal,
  primaryKey,
} from "drizzle-orm/pg-core";
import { relations } from "drizzle-orm";

// Vector type for PostgreSQL with pgvector
const vector = (name: string, config?: { dimensions?: number }) => 
  text(name).$type<string>();

// PostgreSQL Enums
export const adPlacementEnum = pgEnum("ad_placement", [
  "chat_inline",
  "sidebar", 
  "content_promo",
  "chat",
  "default"
]);

export const adStatusEnum = pgEnum("ad_status", ["pending", "active", "paused"]);

export const adTypeEnum = pgEnum("ad_type", [
  "text",
  "banner", 
  "video",
  "hyperlink",
  "popup",
  "thinking"
]);

export const campaignStatusEnum = pgEnum("campaign_status", [
  "active",
  "completed", 
  "paused"
]);

export const pricingModelEnum = pgEnum("pricing_model", [
  "cpc",
  "cpm",
  "flat",
  "affiliate"
]);

// Tables
export const accountRoleValues = pgTable("account_role_values", {
  value: text("value").notNull().primaryKey(),
});

export const adCampaigns = pgTable("ad_campaigns", {
  id: uuid("id").defaultRandom().primaryKey(),
  advertiserId: uuid("advertiser_id").notNull(),
  name: varchar("name", { length: 255 }).notNull(),
  startDate: timestamp("start_date", { withTimezone: true }).notNull(),
  endDate: timestamp("end_date", { withTimezone: true }).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow(),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
  budgetAmount: numeric("budget_amount", { precision: 14, scale: 6 }).notNull(),
  spentAmount: numeric("spent_amount", { precision: 14, scale: 6 }).notNull(),
  currency: char("currency", { length: 3 }).default("USD").notNull(),
  status: campaignStatusEnum("status").default("active").notNull(),
  timeZone: text("time_zone").default("UTC").notNull(),
});

export const adCategories = pgTable("ad_categories", {
  id: uuid("id").defaultRandom().primaryKey(),
  name: varchar("name", { length: 100 }).notNull(),
  description: text("description"),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow(),
});

export const adCategoryRelationships = pgTable("ad_category_relationships", {
  id: uuid("id").defaultRandom().primaryKey(),
  adId: uuid("ad_id"),
  categoryId: uuid("category_id"),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
});

export const adClicks = pgTable("ad_clicks", {
  id: uuid("id").defaultRandom().primaryKey(),
  impressionId: uuid("impression_id").notNull(),
  clickMetadata: jsonb("click_metadata"),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  isBilled: boolean("is_billed").default(false).notNull(),
});

export const adImpressions = pgTable("ad_impressions", {
  id: uuid("id").defaultRandom().primaryKey(),
  messageAdId: uuid("message_ad_id"),
  adId: uuid("ad_id"),
  creatorId: uuid("creator_id"),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow(),
  sessionId: uuid("session_id"),
  status: varchar("status", { length: 20 }).default("pending").notNull(),
  revenueAmount: numeric("revenue_amount", { precision: 14, scale: 6 }).notNull(),
  creatorPayoutAmount: numeric("creator_payout_amount", { precision: 14, scale: 6 }).notNull(),
  currency: char("currency", { length: 3 }).default("USD").notNull(),
  impressionType: text("impression_type"),
  adQueueSessionId: uuid("ad_queue_session_id"),
  adQueuePlacement: text("ad_queue_placement"),
  mcpToolCallId: uuid("mcp_tool_call_id"),
});

export const ads = pgTable("ads", {
  id: uuid("id").defaultRandom().primaryKey(),
  campaignId: uuid("campaign_id").notNull(),
  title: varchar("title", { length: 255 }).notNull(),
  content: text("content").notNull(),
  targetUrl: text("target_url"),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow(),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
  adType: adTypeEnum("ad_type").default("text").notNull(),
  status: adStatusEnum("status").default("pending").notNull(),
  placement: adPlacementEnum("placement").default("default").notNull(),
  pricingModel: pricingModelEnum("pricing_model").default("cpc").notNull(),
  bidAmount: numeric("bid_amount", { precision: 14, scale: 6 }),
  currency: char("currency", { length: 3 }).default("USD").notNull(),
  // Vector embeddings (1536 dimensions for OpenAI)
  embedding: vector("embedding", { dimensions: 1536 }),
});

export const creators = pgTable("creators", {
  id: uuid("id").defaultRandom().primaryKey(),
  userId: text("user_id").references(() => users.id), // Link to Frontend Auth user
  name: varchar("name", { length: 255 }).notNull(),
  email: varchar("email", { length: 255 }).notNull().unique(),
  bio: text("bio"),
  approvalStatus: varchar("approval_status", { length: 20 }).default("pending"),
  approvalDate: timestamp("approval_date", { withTimezone: true }),
  rejectionReason: text("rejection_reason"),
  permissions: jsonb("permissions").default([]),
  lastApprovalCheck: timestamp("last_approval_check", { withTimezone: true }).defaultNow(),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow(),
  deletedAt: timestamp("deleted_at", { withTimezone: true }),
});

export const businessSettings = pgTable("business_settings", {
  id: uuid("id").defaultRandom().primaryKey(),
  creatorId: uuid("creator_id").references(() => creators.id).notNull(),
  adFrequency: varchar("ad_frequency", { length: 20 }).default("normal"),
  revenueVsRelevance: numeric("revenue_vs_relevance", { precision: 3, scale: 2 }).default("0.5"),
  minSecondsBetweenDisplayAds: numeric("min_seconds_between_display_ads").default("30"),
  displayAdSimilarityThreshold: numeric("display_ad_similarity_threshold", { precision: 3, scale: 2 }).default("0.25"),
  isActive: boolean("is_active").default(true),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow(),
});

export const chatSessions = pgTable("chat_sessions", {
  id: uuid("id").defaultRandom().primaryKey(),
  creatorId: uuid("creator_id"),
  startedAt: timestamp("started_at", { withTimezone: true }).defaultNow(),
  endedAt: timestamp("ended_at", { withTimezone: true }),
  metadata: jsonb("metadata"),
});

export const chatMessages = pgTable("chat_messages", {
  id: uuid("id").defaultRandom().primaryKey(),
  sessionId: uuid("session_id").notNull(),
  content: text("content").notNull(),
  role: varchar("role", { length: 20 }).notNull(), // user, assistant, system
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow(),
  // Vector embedding for message content
  embedding: vector("embedding", { dimensions: 1536 }),
});

// Relations
export const campaignsRelations = relations(adCampaigns, ({ many }) => ({
  ads: many(ads),
}));

export const adsRelations = relations(ads, ({ one, many }) => ({
  campaign: one(adCampaigns, {
    fields: [ads.campaignId],
    references: [adCampaigns.id],
  }),
  impressions: many(adImpressions),
  categories: many(adCategoryRelationships),
}));

export const adImpressionsRelations = relations(adImpressions, ({ one, many }) => ({
  ad: one(ads, {
    fields: [adImpressions.adId],
    references: [ads.id],
  }),
  creator: one(creators, {
    fields: [adImpressions.creatorId], 
    references: [creators.id],
  }),
  clicks: many(adClicks),
}));

export const adClicksRelations = relations(adClicks, ({ one }) => ({
  impression: one(adImpressions, {
    fields: [adClicks.impressionId],
    references: [adImpressions.id],
  }),
}));

export const creatorsRelations = relations(creators, ({ one, many }) => ({
  user: one(users, { fields: [creators.userId], references: [users.id] }), // Link to Frontend Auth user
  sessions: many(chatSessions),
  impressions: many(adImpressions),
}));

export const chatSessionsRelations = relations(chatSessions, ({ one, many }) => ({
  creator: one(creators, {
    fields: [chatSessions.creatorId],
    references: [creators.id],
  }),
  messages: many(chatMessages),
}));

export const chatMessagesRelations = relations(chatMessages, ({ one }) => ({
  session: one(chatSessions, {
    fields: [chatMessages.sessionId],
    references: [chatSessions.id],
  }),
}));

// Default ad relationships - supports both global and creator-specific defaults
export const defaultAdRelationship = pgTable("default_ad_relationship", {
  id: uuid("id").defaultRandom().primaryKey(),
  creatorId: uuid("creator_id"), // NULL for global defaults
  adId: uuid("ad_id").notNull().references(() => ads.id, { onDelete: 'cascade' }),
  adType: text("ad_type").notNull(), // 'popup', 'thinking', 'banner', 'video'
  placement: text("placement").notNull(), // 'sidebar', 'modal', 'inline', 'overlay', 'header', 'footer', 'default'
  isGlobalDefault: boolean("is_global_default").default(false).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow().notNull(),
  updatedAt: timestamp("updated_at", { withTimezone: true }).defaultNow().notNull(),
}, (table) => ({
  // Global defaults constraint: only one global default per ad_type/placement
  globalUnique: unique("default_ad_global_unique").on(table.adType, table.placement, table.isGlobalDefault),
  // Creator-specific constraint: one default per creator per ad_type/placement
  creatorUnique: unique("default_ad_relationship_creator_id_ad_type_placement_key").on(table.creatorId, table.adType, table.placement),
  // Foreign key to creators (optional for global defaults)
  creatorFk: table.creatorId ? [table.creatorId] : undefined,
}));

export const defaultAdRelationshipRelations = relations(defaultAdRelationship, ({ one }) => ({
  creator: one(creators, {
    fields: [defaultAdRelationship.creatorId],
    references: [creators.id],
  }),
  ad: one(ads, {
    fields: [defaultAdRelationship.adId],
    references: [ads.id],
  }),
}));

// Frontend Auth Tables (simplified authentication)
export const users = pgTable("users", {
  id: text("id").primaryKey(),
  email: text("email").notNull().unique(),
  name: text("name").notNull(),
  picture: text("picture"),
  emailVerified: boolean("email_verified").default(false).notNull(),
  provider: text("provider").default("google").notNull(),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at")
    .defaultNow()
    .$onUpdate(() => new Date())
    .notNull(),
});

export const apiKeys = pgTable("api_keys", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  key: text("key").notNull().unique(),
  userId: text("user_id")
    .notNull()
    .references(() => users.id, { onDelete: "cascade" }),
  permissions: jsonb("permissions").default({}).notNull(),
  metadata: jsonb("metadata").default({}).notNull(),
  rateLimit: jsonb("rate_limit").default({}).notNull(),
  lastUsedAt: timestamp("last_used_at"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
  updatedAt: timestamp("updated_at")
    .defaultNow()
    .$onUpdate(() => new Date())
    .notNull(),
});

export const apiKeyUsage = pgTable("api_key_usage", {
  id: text("id").primaryKey(),
  apiKeyId: text("api_key_id")
    .notNull()
    .references(() => apiKeys.id, { onDelete: "cascade" }),
  endpoint: text("endpoint").notNull(),
  method: text("method").notNull(),
  statusCode: integer("status_code").notNull(),
  responseTime: integer("response_time"),
  ipAddress: text("ip_address"),
  userAgent: text("user_agent"),
  createdAt: timestamp("created_at").defaultNow().notNull(),
});

// Admin Sessions Table
export const adminSessions = pgTable("admin_sessions", {
  id: uuid("id").primaryKey().defaultRandom(),
  sessionId: varchar("session_id", { length: 128 }).unique().notNull(),
  expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow().notNull(),
  ipAddress: varchar("ip_address", { length: 45 }),
});

// Agreement System Tables
export const agreementVersions = pgTable("agreement_versions", {
  id: uuid("id").primaryKey().defaultRandom(),
  versionString: varchar("version_string", { length: 50 }).notNull().unique(),
  contentHash: varchar("content_hash", { length: 64 }).notNull().unique(),
  contentText: text("content_text").notNull(),
  isActive: boolean("is_active").default(true),
  effectiveDate: timestamp("effective_date", { withTimezone: true }).notNull(),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow().notNull(),
  createdBy: text("created_by"),
  changeSummary: text("change_summary"),
});

export const userAgreements = pgTable("user_agreements", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  agreementVersionId: uuid("agreement_version_id").notNull().references(() => agreementVersions.id),
  acceptedAt: timestamp("accepted_at", { withTimezone: true }).defaultNow().notNull(),
  ipAddress: text("ip_address"),
  userAgent: text("user_agent"),
  acceptanceMethod: varchar("acceptance_method", { length: 50 }).default("clickwrap"),
  createdAt: timestamp("created_at", { withTimezone: true }).defaultNow().notNull(),
}, (table) => ({
  uniqueUserVersion: unique().on(table.userId, table.agreementVersionId)
}));

export const agreementBannerDismissals = pgTable("agreement_banner_dismissals", {
  id: uuid("id").primaryKey().defaultRandom(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  bannerVersionId: uuid("banner_version_id").notNull().references(() => agreementVersions.id),
  dismissedAt: timestamp("dismissed_at", { withTimezone: true }).defaultNow().notNull(),
  ipAddress: text("ip_address"),
  userAgent: text("user_agent"),
});

// Frontend Auth Relations
export const usersRelations = relations(users, ({ many }) => ({
  creators: many(creators), // Link to creator profiles
  apiKeys: many(apiKeys), // Link to API keys
  userAgreements: many(userAgreements),
  agreementBannerDismissals: many(agreementBannerDismissals),
}));

export const apiKeysRelations = relations(apiKeys, ({ one, many }) => ({
  user: one(users, { fields: [apiKeys.userId], references: [users.id] }),
  usage: many(apiKeyUsage),
}));

export const apiKeyUsageRelations = relations(apiKeyUsage, ({ one }) => ({
  apiKey: one(apiKeys, { fields: [apiKeyUsage.apiKeyId], references: [apiKeys.id] }),
}));

// Type exports
export type Ad = typeof ads.$inferSelect;
export type NewAd = typeof ads.$inferInsert;
export type Campaign = typeof adCampaigns.$inferSelect;
export type NewCampaign = typeof adCampaigns.$inferInsert;
export type Creator = typeof creators.$inferSelect;
export type NewCreator = typeof creators.$inferInsert;
export type BusinessSetting = typeof businessSettings.$inferSelect;
export type NewBusinessSetting = typeof businessSettings.$inferInsert;
export type ChatSession = typeof chatSessions.$inferSelect;
export type NewChatSession = typeof chatSessions.$inferInsert;
export type ChatMessage = typeof chatMessages.$inferSelect;
export type NewChatMessage = typeof chatMessages.$inferInsert;
export type DefaultAdRelationship = typeof defaultAdRelationship.$inferSelect;
export type NewDefaultAdRelationship = typeof defaultAdRelationship.$inferInsert;
export type User = typeof users.$inferSelect;
export type NewUser = typeof users.$inferInsert;
export type ApiKey = typeof apiKeys.$inferSelect;
export type NewApiKey = typeof apiKeys.$inferInsert;
export type ApiKeyUsage = typeof apiKeyUsage.$inferSelect;
export type NewApiKeyUsage = typeof apiKeyUsage.$inferInsert;
export type AdminSession = typeof adminSessions.$inferSelect;
export type NewAdminSession = typeof adminSessions.$inferInsert;
export type AgreementVersion = typeof agreementVersions.$inferSelect;
export type NewAgreementVersion = typeof agreementVersions.$inferInsert;
export type UserAgreement = typeof userAgreements.$inferSelect;
export type NewUserAgreement = typeof userAgreements.$inferInsert;
export type AgreementBannerDismissal = typeof agreementBannerDismissals.$inferSelect;
export type NewAgreementBannerDismissal = typeof agreementBannerDismissals.$inferInsert;