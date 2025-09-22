-- Migration 005: Add Admin and Logging Tables
-- Purpose: Add admin sessions and API logging functionality

-- Create admin sessions table
CREATE TABLE IF NOT EXISTS public.admin_sessions (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    session_id varchar(128) NOT NULL UNIQUE,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address varchar(45)
);

-- Create API logs table
CREATE TABLE IF NOT EXISTS public.api_logs (
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

-- Add indexes for performance
CREATE INDEX IF NOT EXISTS idx_admin_sessions_session_id ON public.admin_sessions(session_id);
CREATE INDEX IF NOT EXISTS idx_admin_sessions_expires_at ON public.admin_sessions(expires_at);
CREATE INDEX IF NOT EXISTS idx_api_logs_timestamp ON public.api_logs(timestamp);
CREATE INDEX IF NOT EXISTS idx_api_logs_endpoint ON public.api_logs(endpoint);
CREATE INDEX IF NOT EXISTS idx_api_logs_user_id ON public.api_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_api_logs_status_code ON public.api_logs(status_code);
CREATE INDEX IF NOT EXISTS idx_api_logs_created_at ON public.api_logs(created_at);

-- Add check constraints
ALTER TABLE public.api_logs 
    ADD CONSTRAINT check_api_logs_level 
    CHECK (level IN ('DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'));

-- Add comments
COMMENT ON TABLE public.admin_sessions IS 'Admin authentication sessions';
COMMENT ON TABLE public.api_logs IS 'Real-time API logging for debugging and monitoring';
COMMENT ON COLUMN public.api_logs.details IS 'Additional structured data about the request/response';
COMMENT ON COLUMN public.api_logs.duration IS 'Request duration in milliseconds';
COMMENT ON COLUMN public.admin_sessions.ip_address IS 'IPv4 or IPv6 address of admin user';