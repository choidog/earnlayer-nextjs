-- Migration 004: Add Agreement System Tables
-- Purpose: Add legal agreement tracking and management

-- Create agreement versions table
CREATE TABLE IF NOT EXISTS public.agreement_versions (
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

-- Create user agreements acceptance table
CREATE TABLE IF NOT EXISTS public.user_agreements (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id text NOT NULL REFERENCES public.auth_users(id) ON DELETE CASCADE,
    agreement_version_id uuid NOT NULL REFERENCES public.agreement_versions(id),
    accepted_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text,
    acceptance_method varchar(50) DEFAULT 'clickwrap',
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    UNIQUE(user_id, agreement_version_id)
);

-- Create agreement banner dismissals table
CREATE TABLE IF NOT EXISTS public.agreement_banner_dismissals (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id text NOT NULL REFERENCES public.auth_users(id) ON DELETE CASCADE,
    banner_version_id uuid NOT NULL REFERENCES public.agreement_versions(id),
    dismissed_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text
);

-- Add indexes for performance
CREATE INDEX IF NOT EXISTS idx_agreement_versions_active 
    ON public.agreement_versions(is_active) 
    WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_agreement_versions_effective_date 
    ON public.agreement_versions(effective_date);
CREATE INDEX IF NOT EXISTS idx_user_agreements_user_id 
    ON public.user_agreements(user_id);
CREATE INDEX IF NOT EXISTS idx_user_agreements_version_id 
    ON public.user_agreements(agreement_version_id);
CREATE INDEX IF NOT EXISTS idx_agreement_banner_dismissals_user_id 
    ON public.agreement_banner_dismissals(user_id);

-- Add comments
COMMENT ON TABLE public.agreement_versions IS 'Tracks different versions of user agreements';
COMMENT ON TABLE public.user_agreements IS 'Records user acceptance of specific agreement versions';
COMMENT ON TABLE public.agreement_banner_dismissals IS 'Tracks when users dismiss agreement update banners';
COMMENT ON COLUMN public.agreement_versions.content_hash IS 'SHA256 hash of content_text for integrity verification';
COMMENT ON COLUMN public.agreement_versions.is_active IS 'Whether this is the current active agreement version';
COMMENT ON COLUMN public.user_agreements.acceptance_method IS 'How the user accepted (clickwrap, email, etc.)';