--
-- PostgreSQL database dump
--

-- Dumped from database version 16.10 (Debian 16.10-1.pgdg12+1)
-- Dumped by pg_dump version 17.5

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: drizzle; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA drizzle;


ALTER SCHEMA drizzle OWNER TO postgres;

--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: ad_placement; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.ad_placement AS ENUM (
    'chat_inline',
    'sidebar',
    'content_promo',
    'chat',
    'default'
);


ALTER TYPE public.ad_placement OWNER TO postgres;

--
-- Name: ad_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.ad_status AS ENUM (
    'pending',
    'active',
    'paused'
);


ALTER TYPE public.ad_status OWNER TO postgres;

--
-- Name: ad_type; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.ad_type AS ENUM (
    'text',
    'banner',
    'video',
    'hyperlink',
    'popup',
    'thinking'
);


ALTER TYPE public.ad_type OWNER TO postgres;

--
-- Name: campaign_status; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.campaign_status AS ENUM (
    'active',
    'completed',
    'paused'
);


ALTER TYPE public.campaign_status OWNER TO postgres;

--
-- Name: pricing_model; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.pricing_model AS ENUM (
    'cpc',
    'cpm',
    'flat',
    'affiliate'
);


ALTER TYPE public.pricing_model OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: __drizzle_migrations; Type: TABLE; Schema: drizzle; Owner: postgres
--

CREATE TABLE drizzle.__drizzle_migrations (
    id integer NOT NULL,
    hash text NOT NULL,
    created_at bigint
);


ALTER TABLE drizzle.__drizzle_migrations OWNER TO postgres;

--
-- Name: __drizzle_migrations_id_seq; Type: SEQUENCE; Schema: drizzle; Owner: postgres
--

CREATE SEQUENCE drizzle.__drizzle_migrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE drizzle.__drizzle_migrations_id_seq OWNER TO postgres;

--
-- Name: __drizzle_migrations_id_seq; Type: SEQUENCE OWNED BY; Schema: drizzle; Owner: postgres
--

ALTER SEQUENCE drizzle.__drizzle_migrations_id_seq OWNED BY drizzle.__drizzle_migrations.id;


--
-- Name: account; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.account (
    id text NOT NULL,
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


ALTER TABLE public.account OWNER TO postgres;

--
-- Name: account_role_values; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.account_role_values (
    value text NOT NULL
);


ALTER TABLE public.account_role_values OWNER TO postgres;

--
-- Name: ad_campaigns; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ad_campaigns (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    advertiser_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    start_date timestamp with time zone NOT NULL,
    end_date timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    budget_amount numeric(14,6) NOT NULL,
    spent_amount numeric(14,6) NOT NULL,
    currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    status public.campaign_status DEFAULT 'active'::public.campaign_status NOT NULL,
    time_zone text DEFAULT 'UTC'::text NOT NULL
);


ALTER TABLE public.ad_campaigns OWNER TO postgres;

--
-- Name: ad_categories; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ad_categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.ad_categories OWNER TO postgres;

--
-- Name: ad_category_relationships; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ad_category_relationships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ad_id uuid,
    category_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.ad_category_relationships OWNER TO postgres;

--
-- Name: ad_clicks; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ad_clicks (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    impression_id uuid NOT NULL,
    click_metadata jsonb,
    created_at timestamp with time zone DEFAULT now(),
    is_billed boolean DEFAULT false NOT NULL
);


ALTER TABLE public.ad_clicks OWNER TO postgres;

--
-- Name: ad_impressions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ad_impressions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_ad_id uuid,
    ad_id uuid,
    creator_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    session_id uuid,
    status character varying(20) DEFAULT 'pending'::character varying NOT NULL,
    revenue_amount numeric(14,6) NOT NULL,
    creator_payout_amount numeric(14,6) NOT NULL,
    currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    impression_type text,
    ad_queue_session_id uuid,
    ad_queue_placement text,
    mcp_tool_call_id uuid
);


ALTER TABLE public.ad_impressions OWNER TO postgres;

--
-- Name: admin_sessions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.admin_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id character varying(128) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address character varying(45)
);


ALTER TABLE public.admin_sessions OWNER TO postgres;

--
-- Name: ads; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ads (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid NOT NULL,
    title character varying(255) NOT NULL,
    content text NOT NULL,
    target_url text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    ad_type public.ad_type DEFAULT 'text'::public.ad_type NOT NULL,
    status public.ad_status DEFAULT 'pending'::public.ad_status NOT NULL,
    placement public.ad_placement DEFAULT 'default'::public.ad_placement NOT NULL,
    pricing_model public.pricing_model DEFAULT 'cpc'::public.pricing_model NOT NULL,
    bid_amount numeric(14,6),
    currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    embedding text
);


ALTER TABLE public.ads OWNER TO postgres;

--
-- Name: agreement_banner_dismissals; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.agreement_banner_dismissals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id text NOT NULL,
    banner_version_id uuid NOT NULL,
    dismissed_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text
);


ALTER TABLE public.agreement_banner_dismissals OWNER TO postgres;

--
-- Name: agreement_versions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.agreement_versions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    version_string character varying(50) NOT NULL,
    content_hash character varying(64) NOT NULL,
    content_text text NOT NULL,
    is_active boolean DEFAULT true,
    effective_date timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by text,
    change_summary text
);


ALTER TABLE public.agreement_versions OWNER TO postgres;

--
-- Name: api_key_usage; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.api_key_usage (
    id text NOT NULL,
    api_key_id text NOT NULL,
    endpoint text NOT NULL,
    method text NOT NULL,
    status_code integer NOT NULL,
    response_time integer,
    ip_address text,
    user_agent text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE public.api_key_usage OWNER TO postgres;

--
-- Name: api_keys; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.api_keys (
    id text NOT NULL,
    name text NOT NULL,
    key text NOT NULL,
    user_id text NOT NULL,
    permissions jsonb DEFAULT '{}'::jsonb NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    rate_limit jsonb DEFAULT '{}'::jsonb NOT NULL,
    last_used_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE public.api_keys OWNER TO postgres;

--
-- Name: api_logs; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.api_logs (
    id integer NOT NULL,
    "timestamp" timestamp with time zone DEFAULT now() NOT NULL,
    level character varying(20) NOT NULL,
    endpoint character varying(500) NOT NULL,
    method character varying(10),
    message text NOT NULL,
    details jsonb,
    request_id character varying(100),
    status_code integer,
    duration integer,
    user_id character varying(100),
    ip_address inet,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.api_logs OWNER TO postgres;

--
-- Name: TABLE api_logs; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.api_logs IS 'Real-time API logging for debugging and monitoring';


--
-- Name: api_logs_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.api_logs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.api_logs_id_seq OWNER TO postgres;

--
-- Name: api_logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.api_logs_id_seq OWNED BY public.api_logs.id;


--
-- Name: apikey; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.apikey (
    id text NOT NULL,
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


ALTER TABLE public.apikey OWNER TO postgres;

--
-- Name: business_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.business_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid NOT NULL,
    ad_frequency character varying(20) DEFAULT 'normal'::character varying,
    revenue_vs_relevance numeric(3,2) DEFAULT 0.5,
    min_seconds_between_display_ads numeric DEFAULT '30'::numeric,
    display_ad_similarity_threshold numeric(3,2) DEFAULT 0.25,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.business_settings OWNER TO postgres;

--
-- Name: chat_messages; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.chat_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid NOT NULL,
    content text NOT NULL,
    role character varying(20) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    embedding text
);


ALTER TABLE public.chat_messages OWNER TO postgres;

--
-- Name: chat_sessions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.chat_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid,
    started_at timestamp with time zone DEFAULT now(),
    ended_at timestamp with time zone,
    metadata jsonb
);


ALTER TABLE public.chat_sessions OWNER TO postgres;

--
-- Name: creators; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.creators (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name character varying(255) NOT NULL,
    email character varying(255) NOT NULL,
    bio text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    user_id text,
    approval_status character varying(20) DEFAULT 'pending'::character varying,
    approval_date timestamp with time zone,
    rejection_reason text,
    permissions jsonb DEFAULT '[]'::jsonb,
    last_approval_check timestamp with time zone DEFAULT now()
);


ALTER TABLE public.creators OWNER TO postgres;

--
-- Name: default_ad_relationship; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.default_ad_relationship (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid,
    ad_id uuid NOT NULL,
    ad_type text NOT NULL,
    placement text NOT NULL,
    is_global_default boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.default_ad_relationship OWNER TO postgres;

--
-- Name: session; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.session (
    id text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    token text NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text,
    user_id text NOT NULL
);


ALTER TABLE public.session OWNER TO postgres;

--
-- Name: user; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."user" (
    id text NOT NULL,
    name text NOT NULL,
    email text NOT NULL,
    email_verified boolean DEFAULT false NOT NULL,
    image text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public."user" OWNER TO postgres;

--
-- Name: user_agreements; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_agreements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id text NOT NULL,
    agreement_version_id uuid NOT NULL,
    accepted_at timestamp with time zone DEFAULT now() NOT NULL,
    ip_address text,
    user_agent text,
    acceptance_method character varying(50) DEFAULT 'clickwrap'::character varying,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.user_agreements OWNER TO postgres;

--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    id text NOT NULL,
    email text NOT NULL,
    name text NOT NULL,
    picture text,
    email_verified boolean DEFAULT false NOT NULL,
    provider text DEFAULT 'google'::text NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


ALTER TABLE public.users OWNER TO postgres;

--
-- Name: verification; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.verification (
    id text NOT NULL,
    identifier text NOT NULL,
    value text NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.verification OWNER TO postgres;

--
-- Name: verification_token; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.verification_token (
    identifier text NOT NULL,
    token text NOT NULL,
    expires timestamp without time zone NOT NULL
);


ALTER TABLE public.verification_token OWNER TO postgres;

--
-- Name: __drizzle_migrations id; Type: DEFAULT; Schema: drizzle; Owner: postgres
--

ALTER TABLE ONLY drizzle.__drizzle_migrations ALTER COLUMN id SET DEFAULT nextval('drizzle.__drizzle_migrations_id_seq'::regclass);


--
-- Name: api_logs id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.api_logs ALTER COLUMN id SET DEFAULT nextval('public.api_logs_id_seq'::regclass);


--
-- Name: __drizzle_migrations __drizzle_migrations_pkey; Type: CONSTRAINT; Schema: drizzle; Owner: postgres
--

ALTER TABLE ONLY drizzle.__drizzle_migrations
    ADD CONSTRAINT __drizzle_migrations_pkey PRIMARY KEY (id);


--
-- Name: account account_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_pkey PRIMARY KEY (id);


--
-- Name: account_role_values account_role_values_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account_role_values
    ADD CONSTRAINT account_role_values_pkey PRIMARY KEY (value);


--
-- Name: ad_campaigns ad_campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_campaigns
    ADD CONSTRAINT ad_campaigns_pkey PRIMARY KEY (id);


--
-- Name: ad_categories ad_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_categories
    ADD CONSTRAINT ad_categories_pkey PRIMARY KEY (id);


--
-- Name: ad_category_relationships ad_category_relationships_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_category_relationships
    ADD CONSTRAINT ad_category_relationships_pkey PRIMARY KEY (id);


--
-- Name: ad_clicks ad_clicks_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_clicks
    ADD CONSTRAINT ad_clicks_pkey PRIMARY KEY (id);


--
-- Name: ad_impressions ad_impressions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_pkey PRIMARY KEY (id);


--
-- Name: admin_sessions admin_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.admin_sessions
    ADD CONSTRAINT admin_sessions_pkey PRIMARY KEY (id);


--
-- Name: admin_sessions admin_sessions_session_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.admin_sessions
    ADD CONSTRAINT admin_sessions_session_id_key UNIQUE (session_id);


--
-- Name: ads ads_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ads
    ADD CONSTRAINT ads_pkey PRIMARY KEY (id);


--
-- Name: agreement_banner_dismissals agreement_banner_dismissals_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreement_banner_dismissals
    ADD CONSTRAINT agreement_banner_dismissals_pkey PRIMARY KEY (id);


--
-- Name: agreement_versions agreement_versions_content_hash_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreement_versions
    ADD CONSTRAINT agreement_versions_content_hash_key UNIQUE (content_hash);


--
-- Name: agreement_versions agreement_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreement_versions
    ADD CONSTRAINT agreement_versions_pkey PRIMARY KEY (id);


--
-- Name: agreement_versions agreement_versions_version_string_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreement_versions
    ADD CONSTRAINT agreement_versions_version_string_key UNIQUE (version_string);


--
-- Name: api_key_usage api_key_usage_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.api_key_usage
    ADD CONSTRAINT api_key_usage_pkey PRIMARY KEY (id);


--
-- Name: api_keys api_keys_key_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_key_key UNIQUE (key);


--
-- Name: api_keys api_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_pkey PRIMARY KEY (id);


--
-- Name: api_logs api_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.api_logs
    ADD CONSTRAINT api_logs_pkey PRIMARY KEY (id);


--
-- Name: apikey apikey_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.apikey
    ADD CONSTRAINT apikey_pkey PRIMARY KEY (id);


--
-- Name: business_settings business_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_settings
    ADD CONSTRAINT business_settings_pkey PRIMARY KEY (id);


--
-- Name: chat_messages chat_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);


--
-- Name: chat_sessions chat_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chat_sessions
    ADD CONSTRAINT chat_sessions_pkey PRIMARY KEY (id);


--
-- Name: creators creators_email_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creators
    ADD CONSTRAINT creators_email_unique UNIQUE (email);


--
-- Name: creators creators_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creators
    ADD CONSTRAINT creators_pkey PRIMARY KEY (id);


--
-- Name: default_ad_relationship default_ad_global_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.default_ad_relationship
    ADD CONSTRAINT default_ad_global_unique UNIQUE (ad_type, placement, is_global_default);


--
-- Name: default_ad_relationship default_ad_relationship_creator_id_ad_type_placement_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.default_ad_relationship
    ADD CONSTRAINT default_ad_relationship_creator_id_ad_type_placement_key UNIQUE (creator_id, ad_type, placement);


--
-- Name: default_ad_relationship default_ad_relationship_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.default_ad_relationship
    ADD CONSTRAINT default_ad_relationship_pkey PRIMARY KEY (id);


--
-- Name: session session_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.session
    ADD CONSTRAINT session_pkey PRIMARY KEY (id);


--
-- Name: session session_token_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.session
    ADD CONSTRAINT session_token_key UNIQUE (token);


--
-- Name: user_agreements user_agreements_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_agreements
    ADD CONSTRAINT user_agreements_pkey PRIMARY KEY (id);


--
-- Name: user_agreements user_agreements_user_id_agreement_version_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_agreements
    ADD CONSTRAINT user_agreements_user_id_agreement_version_id_key UNIQUE (user_id, agreement_version_id);


--
-- Name: user user_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_email_key UNIQUE (email);


--
-- Name: user user_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."user"
    ADD CONSTRAINT user_pkey PRIMARY KEY (id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: verification verification_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.verification
    ADD CONSTRAINT verification_pkey PRIMARY KEY (id);


--
-- Name: verification_token verification_token_identifier_token_pk; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.verification_token
    ADD CONSTRAINT verification_token_identifier_token_pk PRIMARY KEY (identifier, token);


--
-- Name: idx_agreement_versions_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_agreement_versions_active ON public.agreement_versions USING btree (is_active) WHERE (is_active = true);


--
-- Name: idx_api_key_usage_api_key_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_api_key_usage_api_key_id ON public.api_key_usage USING btree (api_key_id);


--
-- Name: idx_api_key_usage_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_api_key_usage_created_at ON public.api_key_usage USING btree (created_at);


--
-- Name: idx_api_keys_key; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_api_keys_key ON public.api_keys USING btree (key);


--
-- Name: idx_api_keys_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_api_keys_user_id ON public.api_keys USING btree (user_id);


--
-- Name: idx_api_logs_endpoint; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_api_logs_endpoint ON public.api_logs USING btree (endpoint);


--
-- Name: idx_api_logs_level; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_api_logs_level ON public.api_logs USING btree (level);


--
-- Name: idx_api_logs_request_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_api_logs_request_id ON public.api_logs USING btree (request_id);


--
-- Name: idx_api_logs_timestamp; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_api_logs_timestamp ON public.api_logs USING btree ("timestamp" DESC);


--
-- Name: idx_api_logs_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_api_logs_user_id ON public.api_logs USING btree (user_id);


--
-- Name: idx_banner_dismissals_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_banner_dismissals_user_id ON public.agreement_banner_dismissals USING btree (user_id);


--
-- Name: idx_user_agreements_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_agreements_user_id ON public.user_agreements USING btree (user_id);


--
-- Name: idx_user_agreements_version_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_user_agreements_version_id ON public.user_agreements USING btree (agreement_version_id);


--
-- Name: idx_users_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_users_email ON public.users USING btree (email);


--
-- Name: account account_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.account
    ADD CONSTRAINT account_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: agreement_banner_dismissals agreement_banner_dismissals_banner_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreement_banner_dismissals
    ADD CONSTRAINT agreement_banner_dismissals_banner_version_id_fkey FOREIGN KEY (banner_version_id) REFERENCES public.agreement_versions(id);


--
-- Name: agreement_banner_dismissals agreement_banner_dismissals_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.agreement_banner_dismissals
    ADD CONSTRAINT agreement_banner_dismissals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: api_key_usage api_key_usage_api_key_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.api_key_usage
    ADD CONSTRAINT api_key_usage_api_key_id_fkey FOREIGN KEY (api_key_id) REFERENCES public.api_keys(id) ON DELETE CASCADE;


--
-- Name: api_keys api_keys_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.api_keys
    ADD CONSTRAINT api_keys_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: apikey apikey_user_id_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.apikey
    ADD CONSTRAINT apikey_user_id_user_id_fk FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: business_settings business_settings_creator_id_creators_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_settings
    ADD CONSTRAINT business_settings_creator_id_creators_id_fk FOREIGN KEY (creator_id) REFERENCES public.creators(id);


--
-- Name: creators creators_user_id_user_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creators
    ADD CONSTRAINT creators_user_id_user_id_fk FOREIGN KEY (user_id) REFERENCES public."user"(id);


--
-- Name: default_ad_relationship default_ad_relationship_ad_id_ads_id_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.default_ad_relationship
    ADD CONSTRAINT default_ad_relationship_ad_id_ads_id_fk FOREIGN KEY (ad_id) REFERENCES public.ads(id) ON DELETE CASCADE;


--
-- Name: session session_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.session
    ADD CONSTRAINT session_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- Name: user_agreements user_agreements_agreement_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_agreements
    ADD CONSTRAINT user_agreements_agreement_version_id_fkey FOREIGN KEY (agreement_version_id) REFERENCES public.agreement_versions(id);


--
-- Name: user_agreements user_agreements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_agreements
    ADD CONSTRAINT user_agreements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."user"(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

