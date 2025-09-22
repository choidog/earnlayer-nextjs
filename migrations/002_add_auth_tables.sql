-- Migration 002: Add Authentication Tables
-- Purpose: Add Better Auth and Frontend Auth tables

-- Create new auth users table (text-based IDs for OAuth)
CREATE TABLE IF NOT EXISTS public.users (
    id text PRIMARY KEY,
    email text NOT NULL UNIQUE,
    name text NOT NULL,
    picture text,
    email_verified boolean DEFAULT false NOT NULL,
    provider text DEFAULT 'google' NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);

-- Create OAuth account linkage table
CREATE TABLE IF NOT EXISTS public.account (
    id text PRIMARY KEY,
    account_id text NOT NULL,
    provider_id text NOT NULL,
    user_id text NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
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

-- Create session table for Better Auth
CREATE TABLE IF NOT EXISTS public.session (
    id text PRIMARY KEY,
    expires_at timestamp without time zone NOT NULL,
    token text NOT NULL UNIQUE,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text,
    user_id text NOT NULL REFERENCES public.users(id) ON DELETE CASCADE
);

-- Create legacy user table (Better Auth compatibility)
CREATE TABLE IF NOT EXISTS public."user" (
    id text PRIMARY KEY,
    name text NOT NULL,
    email text NOT NULL UNIQUE,
    email_verified boolean DEFAULT false NOT NULL,
    image text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);

-- Create verification tables
CREATE TABLE IF NOT EXISTS public.verification (
    id text PRIMARY KEY,
    identifier text NOT NULL,
    value text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.verification_token (
    identifier text NOT NULL,
    token text NOT NULL,
    expires timestamp without time zone NOT NULL,
    PRIMARY KEY (identifier, token)
);

-- Add indexes for performance
CREATE INDEX IF NOT EXISTS idx_account_user_id ON public.account(user_id);
CREATE INDEX IF NOT EXISTS idx_session_user_id ON public.session(user_id);
CREATE INDEX IF NOT EXISTS idx_session_token ON public.session(token);
CREATE INDEX IF NOT EXISTS idx_session_expires ON public.session(expires_at);

-- Add comments
COMMENT ON TABLE public.users IS 'Frontend authentication users via OAuth providers';
COMMENT ON TABLE public.account IS 'OAuth account linkages for users';
COMMENT ON TABLE public.session IS 'Active user sessions';
COMMENT ON TABLE public."user" IS 'Legacy Better Auth user table for compatibility';
COMMENT ON TABLE public.verification IS 'Email/account verification tracking';
COMMENT ON TABLE public.verification_token IS 'Verification tokens for account activation';