-- Create ad_campaigns table
CREATE TABLE IF NOT EXISTS "ad_campaigns" (
	"id" text PRIMARY KEY NOT NULL,
	"advertiser_id" text NOT NULL,
	"name" text NOT NULL,
	"start_date" timestamp NOT NULL,
	"end_date" timestamp NOT NULL,
	"budget" integer NOT NULL,
	"status" text NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	"deleted_at" timestamp
);

-- Create ads table
CREATE TABLE IF NOT EXISTS "ads" (
	"id" text PRIMARY KEY NOT NULL,
	"campaign_id" text NOT NULL,
	"title" text NOT NULL,
	"target_url" text NOT NULL,
	"ad_type" text NOT NULL,
	"pricing_model" text NOT NULL,
	"content" text,
	"status" text NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	"deleted_at" timestamp,
	"embedding" vector(1536),
	CONSTRAINT "ads_campaign_id_fk" FOREIGN KEY ("campaign_id") REFERENCES "ad_campaigns"("id") ON DELETE cascade
);

-- Create creators table if it doesn't exist
CREATE TABLE IF NOT EXISTS "creators" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text,
	"name" text NOT NULL,
	"bio" text,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "creators_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "user"("id") ON DELETE set null
);