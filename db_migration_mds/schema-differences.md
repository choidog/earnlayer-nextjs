# Schema Differences: Old vs New Database Architecture

## Overview

This document outlines the differences between the old database schema (schemas/cloud) and the new schema (schemas-nextjs/cloud) that has been implemented by your co-founder. The old schema needs to be updated to support the new features while maintaining its better structure.

## New Tables to Add to Old Schema

### 1. Authentication Tables (Better Auth/Frontend Auth)

#### `users` table (new auth system)
```sql
CREATE TABLE public.users (
    id text PRIMARY KEY,
    email text NOT NULL UNIQUE,
    name text NOT NULL,
    picture text,
    email_verified boolean DEFAULT false NOT NULL,
    provider text DEFAULT 'google' NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);
```

#### `account` table (OAuth linkage)
```sql
CREATE TABLE public.account (
    id text PRIMARY KEY,
    account_id text NOT NULL,
    provider_id text NOT NULL,
    user_id text NOT NULL,
    access_token text,
    refresh_token text,
    id_token text,
    access_token_expires_at timestamp without time zone,
    refresh_token_expires_at timestamp without time zone,
    scope text,
    password text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);
```

#### `session` table (Better Auth sessions)
```sql
CREATE TABLE public.session (
    id text PRIMARY KEY,
    expires_at timestamp without time zone NOT NULL,
    token text NOT NULL UNIQUE,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text,
    user_id text NOT NULL
);
```

#### `user` table (Better Auth legacy)
```sql
CREATE TABLE public."user" (
    id text PRIMARY KEY,
    name text NOT NULL,
    email text NOT NULL UNIQUE,
    email_verified boolean DEFAULT false NOT NULL,
    image text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);
```

#### `verification` table
```sql
CREATE TABLE public.verification (
    id text PRIMARY KEY,
    identifier text NOT NULL,
    value text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);
```

#### `verification_token` table
```sql
CREATE TABLE public.verification_token (
    identifier text NOT NULL,
    token text NOT NULL,
    expires timestamp without time zone NOT NULL,
    PRIMARY KEY (identifier, token)
);
```

### 2. API Management Tables

#### `api_keys` table (new implementation)
```sql
CREATE TABLE public.api_keys (
    id text PRIMARY KEY,
    name text NOT NULL,
    key text NOT NULL UNIQUE,
    user_id text NOT NULL,
    permissions jsonb DEFAULT '{}' NOT NULL,
    metadata jsonb DEFAULT '{}' NOT NULL,
    rate_limit jsonb DEFAULT '{}' NOT NULL,
    last_used_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);
```

#### `api_key_usage` table
```sql
CREATE TABLE public.api_key_usage (
    id text PRIMARY KEY,
    api_key_id text NOT NULL,
    endpoint text NOT NULL,
    method text NOT NULL,
    status_code integer NOT NULL,
    response_time integer,
    ip_address text,
    user_agent text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);
```

#### `apikey` table (legacy, still referenced)
```sql
CREATE TABLE public.apikey (
    id text PRIMARY KEY,
    name text,
    start text,
    prefix text,
    key text NOT NULL,
    user_id text NOT NULL,
    refill_interval integer,
    refill_amount integer,
    last_refill_at timestamp without time zone,
    enabled boolean DEFAULT true,
    rate_limit_enabled boolean DEFAULT true,
    rate_limit_time_window integer DEFAULT 86400000,
    rate_limit_max integer DEFAULT 10,
    request_count integer DEFAULT 0,
    remaining integer,
    last_request timestamp without time zone,
    expires_at timestamp without time zone,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    permissions text,
    metadata text
);
```

### 3. Agreement System Tables

#### `agreement_versions` table
```sql
CREATE TABLE public.agreement_versions (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    version_string varchar(50) NOT NULL UNIQUE,
    content_hash varchar(64) NOT NULL UNIQUE,
    content_text text NOT NULL,
    is_active boolean DEFAULT true,
    effective_date timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text,
    change_summary text
);
```

#### `user_agreements` table
```sql
CREATE TABLE public.user_agreements (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id text NOT NULL,
    agreement_version_id uuid NOT NULL,
    accepted_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text,
    acceptance_method varchar(50) DEFAULT 'clickwrap',
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    UNIQUE(user_id, agreement_version_id)
);
```

#### `agreement_banner_dismissals` table
```sql
CREATE TABLE public.agreement_banner_dismissals (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id text NOT NULL,
    banner_version_id uuid NOT NULL,
    dismissed_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text
);
```

### 4. Admin Tables

#### `admin_sessions` table
```sql
CREATE TABLE public.admin_sessions (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id varchar(128) NOT NULL UNIQUE,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address varchar(45)
);
```

### 5. Logging Tables

#### `api_logs` table
```sql
CREATE TABLE public.api_logs (
    id serial PRIMARY KEY,
    timestamp timestamp with time zone DEFAULT now() NOT NULL,
    level varchar(20) NOT NULL,
    endpoint varchar(500) NOT NULL,
    method varchar(10),
    message text NOT NULL,
    details jsonb,
    request_id varchar(100),
    status_code integer,
    duration integer,
    user_id varchar(100),
    ip_address inet,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);
```

### 6. Drizzle Migration Table

#### `drizzle.__drizzle_migrations` table
```sql
CREATE SCHEMA drizzle;

CREATE TABLE drizzle.__drizzle_migrations (
    id serial PRIMARY KEY,
    hash text NOT NULL,
    created_at bigint
);
```

## Fields to Add to Existing Tables

### 1. `creators` table modifications
Add the following fields:
- `user_id text` - Link to Frontend Auth user
- `email varchar(255) NOT NULL UNIQUE` - Email field (currently missing)
- `approval_status varchar(20) DEFAULT 'pending'` - Approval workflow
- `approval_date timestamp with time zone` - When approved
- `rejection_reason text` - If rejected
- `permissions jsonb DEFAULT '[]'` - Creator permissions
- `last_approval_check timestamp with time zone DEFAULT now()` - Last check time

### 2. `ads` table modifications
Change/Add the following:
- Rename `url` to `target_url` (or add as alias)
- Rename `description` to `content` (or add as alias)
- Add `placement ad_placement DEFAULT 'default'` enum field
- Add `bid_amount numeric(14,6)` - For bidding system
- Change `embedding` from `vector(1536)` to `text` type (for compatibility)

### 3. `chat_messages` table modifications
Change/Add:
- Rename `message` to `content`
- Rename `is_user` to `role varchar(20)` with values: 'user', 'assistant', 'system'
- Change `embedding` from `vector(1536)` to `text` type

### 4. `ad_impressions` table modifications
Add the following fields:
- `mcp_tool_call_id uuid` - For MCP tracking

### 5. `business_settings` table modifications
Change numeric types:
- `min_seconds_between_display_ads` from integer to numeric

## Type/Enum Modifications

The new schema uses the same enums but the old schema has additional safety features:
- Custom domain `money_amount` for financial values
- More constraints and checks on tables

## Key Differences in Architecture

### 1. Authentication System
- Old: Custom user/auth system with UUID-based users
- New: Better Auth with text-based user IDs and OAuth integration

### 2. API Key System
- Old: Simple API key in creators table
- New: Dedicated api_keys table with permissions and rate limiting

### 3. User Identification
- Old: UUID-based user IDs throughout
- New: Text-based user IDs (from OAuth providers)

### 4. Vector Storage
- Old: Uses native `vector(1536)` type
- New: Stores embeddings as text (likely base64 encoded)

### 5. Session Management
- Old: Only chat_sessions
- New: Additional user sessions for auth

## Foreign Key Relationships to Add

1. `creators.user_id` → `users.id`
2. `api_keys.user_id` → `users.id`
3. `api_key_usage.api_key_id` → `api_keys.id`
4. `user_agreements.user_id` → `users.id`
5. `user_agreements.agreement_version_id` → `agreement_versions.id`
6. `agreement_banner_dismissals.user_id` → `users.id`
7. `agreement_banner_dismissals.banner_version_id` → `agreement_versions.id`
8. `account.user_id` → `users.id`
9. `session.user_id` → `users.id`

## Indexes to Add

1. `idx_api_key_usage_api_key_id` on api_key_usage(api_key_id)
2. `idx_agreement_versions_active` on agreement_versions(is_active) WHERE is_active = true
3. Index on api_logs for performance
4. Indexes on foreign key columns for joins

## Migration Considerations

1. **User Migration**: Need to map old UUID users to new text-based auth users
2. **Creator Linkage**: Link existing creators to new user accounts
3. **API Key Migration**: Migrate any existing API keys to new structure
4. **Embedding Format**: Convert vector embeddings to text format
5. **Data Integrity**: Ensure all foreign keys are properly linked
6. **Backwards Compatibility**: Some tables may need to support both old and new patterns during transition