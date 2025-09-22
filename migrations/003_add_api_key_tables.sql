-- Migration 003: Add API Key Management Tables
-- Purpose: Add modern API key system with permissions and rate limiting

-- Create new API keys table
CREATE TABLE IF NOT EXISTS public.api_keys (
    id text PRIMARY KEY,
    name text NOT NULL,
    key text NOT NULL UNIQUE,
    user_id text NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    permissions jsonb DEFAULT '{}' NOT NULL,
    metadata jsonb DEFAULT '{}' NOT NULL,
    rate_limit jsonb DEFAULT '{}' NOT NULL,
    last_used_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- Create API key usage tracking table
CREATE TABLE IF NOT EXISTS public.api_key_usage (
    id text PRIMARY KEY,
    api_key_id text NOT NULL REFERENCES public.api_keys(id) ON DELETE CASCADE,
    endpoint text NOT NULL,
    method text NOT NULL,
    status_code integer NOT NULL,
    response_time integer,
    ip_address text,
    user_agent text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- Create legacy API key table (for backwards compatibility)
CREATE TABLE IF NOT EXISTS public.apikey (
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

-- Add indexes for performance
CREATE INDEX IF NOT EXISTS idx_api_keys_user_id ON public.api_keys(user_id);
CREATE INDEX IF NOT EXISTS idx_api_keys_key ON public.api_keys(key);
CREATE INDEX IF NOT EXISTS idx_api_key_usage_api_key_id ON public.api_key_usage(api_key_id);
CREATE INDEX IF NOT EXISTS idx_api_key_usage_created_at ON public.api_key_usage(created_at);
CREATE INDEX IF NOT EXISTS idx_apikey_user_id ON public.apikey(user_id);

-- Add update trigger for api_keys
CREATE OR REPLACE FUNCTION update_api_keys_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_api_keys_updated_at_trigger
    BEFORE UPDATE ON public.api_keys
    FOR EACH ROW
    EXECUTE FUNCTION update_api_keys_updated_at();

-- Add comments
COMMENT ON TABLE public.api_keys IS 'Modern API key management with permissions and rate limiting';
COMMENT ON TABLE public.api_key_usage IS 'Tracks API key usage for analytics and rate limiting';
COMMENT ON TABLE public.apikey IS 'Legacy API key table for backwards compatibility';
COMMENT ON COLUMN public.api_keys.permissions IS 'JSON object defining API key permissions';
COMMENT ON COLUMN public.api_keys.rate_limit IS 'JSON object defining rate limit configuration';
COMMENT ON COLUMN public.api_keys.metadata IS 'Additional metadata for the API key';