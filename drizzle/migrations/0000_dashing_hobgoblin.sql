CREATE TYPE "public"."ad_placement" AS ENUM('chat_inline', 'sidebar', 'content_promo', 'chat', 'default');--> statement-breakpoint
CREATE TYPE "public"."ad_status" AS ENUM('pending', 'active', 'paused');--> statement-breakpoint
CREATE TYPE "public"."ad_type" AS ENUM('text', 'banner', 'video', 'hyperlink', 'popup', 'thinking');--> statement-breakpoint
CREATE TYPE "public"."campaign_status" AS ENUM('active', 'completed', 'paused');--> statement-breakpoint
CREATE TYPE "public"."pricing_model" AS ENUM('cpc', 'cpm', 'flat', 'affiliate');--> statement-breakpoint
CREATE TABLE "account_role_values" (
	"value" text PRIMARY KEY NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ad_campaigns" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"advertiser_id" uuid NOT NULL,
	"name" varchar(255) NOT NULL,
	"start_date" timestamp with time zone NOT NULL,
	"end_date" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	"deleted_at" timestamp with time zone,
	"budget_amount" numeric(14, 6) NOT NULL,
	"spent_amount" numeric(14, 6) NOT NULL,
	"currency" char(3) DEFAULT 'USD' NOT NULL,
	"status" "campaign_status" DEFAULT 'active' NOT NULL,
	"time_zone" text DEFAULT 'UTC' NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ad_categories" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"name" varchar(100) NOT NULL,
	"description" text,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now()
);
--> statement-breakpoint
CREATE TABLE "ad_category_relationships" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"ad_id" uuid,
	"category_id" uuid,
	"created_at" timestamp with time zone DEFAULT now()
);
--> statement-breakpoint
CREATE TABLE "ad_clicks" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"impression_id" uuid NOT NULL,
	"click_metadata" jsonb,
	"created_at" timestamp with time zone DEFAULT now(),
	"is_billed" boolean DEFAULT false NOT NULL
);
--> statement-breakpoint
CREATE TABLE "ad_impressions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"message_ad_id" uuid,
	"ad_id" uuid,
	"creator_id" uuid,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	"session_id" uuid,
	"status" varchar(20) DEFAULT 'pending' NOT NULL,
	"revenue_amount" numeric(14, 6) NOT NULL,
	"creator_payout_amount" numeric(14, 6) NOT NULL,
	"currency" char(3) DEFAULT 'USD' NOT NULL,
	"impression_type" text,
	"ad_queue_session_id" uuid,
	"ad_queue_placement" text,
	"mcp_tool_call_id" uuid
);
--> statement-breakpoint
CREATE TABLE "ads" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"campaign_id" uuid NOT NULL,
	"title" varchar(255) NOT NULL,
	"content" text NOT NULL,
	"target_url" text,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	"deleted_at" timestamp with time zone,
	"ad_type" "ad_type" DEFAULT 'text' NOT NULL,
	"status" "ad_status" DEFAULT 'pending' NOT NULL,
	"placement" "ad_placement" DEFAULT 'default' NOT NULL,
	"pricing_model" "pricing_model" DEFAULT 'cpc' NOT NULL,
	"bid_amount" numeric(14, 6),
	"currency" char(3) DEFAULT 'USD' NOT NULL,
	"embedding" text
);
--> statement-breakpoint
CREATE TABLE "business_settings" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"creator_id" uuid NOT NULL,
	"ad_frequency" varchar(20) DEFAULT 'normal',
	"revenue_vs_relevance" numeric(3, 2) DEFAULT '0.5',
	"min_seconds_between_display_ads" numeric DEFAULT '30',
	"display_ad_similarity_threshold" numeric(3, 2) DEFAULT '0.25',
	"is_active" boolean DEFAULT true,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now()
);
--> statement-breakpoint
CREATE TABLE "chat_messages" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"session_id" uuid NOT NULL,
	"content" text NOT NULL,
	"role" varchar(20) NOT NULL,
	"created_at" timestamp with time zone DEFAULT now(),
	"embedding" text
);
--> statement-breakpoint
CREATE TABLE "chat_sessions" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"creator_id" uuid,
	"started_at" timestamp with time zone DEFAULT now(),
	"ended_at" timestamp with time zone,
	"metadata" jsonb
);
--> statement-breakpoint
CREATE TABLE "creators" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"name" varchar(255) NOT NULL,
	"email" varchar(255) NOT NULL,
	"bio" text,
	"created_at" timestamp with time zone DEFAULT now(),
	"updated_at" timestamp with time zone DEFAULT now(),
	"deleted_at" timestamp with time zone,
	CONSTRAINT "creators_email_unique" UNIQUE("email")
);
--> statement-breakpoint
CREATE TABLE "default_ad_relationship" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"creator_id" uuid,
	"ad_id" uuid NOT NULL,
	"ad_type" text NOT NULL,
	"placement" text NOT NULL,
	"is_global_default" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "default_ad_global_unique" UNIQUE("ad_type","placement","is_global_default"),
	CONSTRAINT "default_ad_relationship_creator_id_ad_type_placement_key" UNIQUE("creator_id","ad_type","placement")
);
--> statement-breakpoint
ALTER TABLE "business_settings" ADD CONSTRAINT "business_settings_creator_id_creators_id_fk" FOREIGN KEY ("creator_id") REFERENCES "public"."creators"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "default_ad_relationship" ADD CONSTRAINT "default_ad_relationship_ad_id_ads_id_fk" FOREIGN KEY ("ad_id") REFERENCES "public"."ads"("id") ON DELETE cascade ON UPDATE no action;