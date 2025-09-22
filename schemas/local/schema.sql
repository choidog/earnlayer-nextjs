--
-- PostgreSQL database dump
--

-- Dumped from database version 17.5
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
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


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
-- Name: money_amount; Type: DOMAIN; Schema: public; Owner: postgres
--

CREATE DOMAIN public.money_amount AS numeric(14,6)
	CONSTRAINT money_amount_v2_check CHECK ((VALUE >= (0)::numeric));


ALTER DOMAIN public.money_amount OWNER TO postgres;

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

--
-- Name: cleanup_inactive_sessions(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cleanup_inactive_sessions() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE chat_sessions
    SET ended_at = now()
    WHERE ended_at IS NULL
    AND started_at < now() - interval '24 hours';
END;
$$;


ALTER FUNCTION public.cleanup_inactive_sessions() OWNER TO postgres;

--
-- Name: enforce_campaign_active_for_ads(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enforce_campaign_active_for_ads() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_campaign_status text;   -- was campaign_status enum
BEGIN
    -- Only validate when the ad is being set to 'active'
    IF NEW.status = 'active' THEN
        SELECT status INTO v_campaign_status
        FROM ad_campaigns
        WHERE id = NEW.campaign_id;

        IF v_campaign_status IS DISTINCT FROM 'active' THEN
            RAISE EXCEPTION
              'Cannot activate ad %. Campaign % is currently %',
              NEW.id, NEW.campaign_id, v_campaign_status;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.enforce_campaign_active_for_ads() OWNER TO postgres;

--
-- Name: refresh_effective_cpc_rates(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.refresh_effective_cpc_rates() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  TRUNCATE public.effective_cpc_rates;

  INSERT INTO public.effective_cpc_rates
  SELECT
    cr.id,
    ac.id,
    pl.placement,
    pl.ad_type,
    CASE 
      -- For affiliate ads, use commission rate from creator_affiliate_codes if available
      WHEN EXISTS (
        SELECT 1 FROM public.ads a 
        WHERE a.campaign_id = ac.id 
          AND a.pricing_model = 'affiliate'
          AND a.status = 'active'
      ) THEN
        COALESCE(
          (SELECT cac.commission_rate 
           FROM public.creator_affiliate_codes cac 
           WHERE cac.creator_id = cr.id 
             AND cac.advertiser_id = ac.advertiser_id 
             AND cac.is_active = true 
             AND cac.deleted_at IS NULL
           LIMIT 1),
          cco.cpc_rate_amount,
          cpd.cpc_rate_amount,
          cs.default_cpc,
          0.01
        )::public.money_amount
      -- For non-affiliate ads, use existing logic
      ELSE
        COALESCE(
          cco.cpc_rate_amount,
          cpd.cpc_rate_amount,
          cs.default_cpc,
          0.01
        )::public.money_amount
    END AS effective_cpc_rate
  FROM public.creators cr
  JOIN public.creator_settings cs ON cs.creator_id = cr.id
  JOIN public.ad_campaigns   ac ON ac.status = 'active'
  CROSS JOIN (
    VALUES
      -- Original ad type/placement combinations
      ('chat_inline'::ad_placement ,'text' ::ad_type ),
      ('chat_inline'::ad_placement ,'video'::ad_type ),
      ('sidebar'    ::ad_placement ,'banner'::ad_type),
      ('content_promo'::ad_placement,'banner'::ad_type),
      -- NEW: Missing ad type/placement combinations for affiliate ads
      ('chat_inline'::ad_placement ,'hyperlink'::ad_type ),
      ('sidebar'    ::ad_placement ,'hyperlink'::ad_type ),
      ('chat_inline'::ad_placement ,'popup'::ad_type ),
      ('sidebar'    ::ad_placement ,'popup'::ad_type ),
      ('content_promo'::ad_placement,'popup'::ad_type )
  ) AS pl(placement, ad_type)
  LEFT JOIN public.campaign_cpc_rates cpd
         ON cpd.campaign_id = ac.id
        AND cpd.placement   = pl.placement
        AND cpd.ad_type     = pl.ad_type
  LEFT JOIN public.creator_campaign_cpc_rates cco
         ON cco.campaign_id = ac.id
        AND cco.creator_id  = cr.id
        AND cco.placement   = pl.placement
        AND cco.ad_type     = pl.ad_type
  -- skip blocked advertiser-creator pairs
  WHERE cr.is_active
    AND NOT EXISTS (
        SELECT 1
        FROM public.creator_advertiser_blocklists bl
        WHERE bl.creator_id    = cr.id
          AND bl.advertiser_id = ac.advertiser_id
    );
END;
$$;


ALTER FUNCTION public.refresh_effective_cpc_rates() OWNER TO postgres;

--
-- Name: sync_campaign_spent_and_status(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_campaign_spent_and_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_campaign_id    uuid;
    v_spent_amount   public.money_amount;
BEGIN
    -- Locate parent campaign
    SELECT campaign_id INTO v_campaign_id
    FROM   public.ads
    WHERE  id = NEW.ad_id;

    -- Atomically update and capture the new spend total
    UPDATE public.ad_campaigns
    SET    spent_amount = spent_amount + NEW.revenue_amount
    WHERE  id = v_campaign_id
    RETURNING spent_amount INTO v_spent_amount;   -- row is locked

    -- Auto-complete when the budget is exhausted
    UPDATE public.ad_campaigns
    SET    status = 'completed'
    WHERE  id = v_campaign_id
      AND  v_spent_amount >= budget_amount;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.sync_campaign_spent_and_status() OWNER TO postgres;

--
-- Name: trigger_refresh_effective_cpc_rates(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trigger_refresh_effective_cpc_rates() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM public.refresh_effective_cpc_rates();
    RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION public.trigger_refresh_effective_cpc_rates() OWNER TO postgres;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_updated_at_column() OWNER TO postgres;

--
-- Name: validate_embeddings_source_fk(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.validate_embeddings_source_fk() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    CASE NEW.source_table
        WHEN 'content' THEN
            IF NOT EXISTS (
                SELECT 1 FROM public.content c WHERE c.id = NEW.source_id
            ) THEN
                RAISE EXCEPTION
                    'embeddings row references non-existent content id %',
                    NEW.source_id
                    USING ERRCODE = 'foreign_key_violation';
            END IF;

        WHEN 'ads' THEN
            IF NOT EXISTS (
                SELECT 1 FROM public.ads a WHERE a.id = NEW.source_id
            ) THEN
                RAISE EXCEPTION
                    'embeddings row references non-existent ad id %',
                    NEW.source_id
                    USING ERRCODE = 'foreign_key_violation';
            END IF;

        ELSE
            RAISE EXCEPTION
                'embeddings.source_table must be content or ads, got %',
                NEW.source_table
                USING ERRCODE = 'check_violation';
    END CASE;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.validate_embeddings_source_fk() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

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
    budget_amount public.money_amount NOT NULL,
    spent_amount public.money_amount NOT NULL,
    currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    status public.campaign_status DEFAULT 'active'::public.campaign_status NOT NULL,
    is_out_of_budget boolean GENERATED ALWAYS AS (((spent_amount)::numeric >= (budget_amount)::numeric)) STORED,
    time_zone text DEFAULT 'UTC'::text NOT NULL,
    CONSTRAINT chk_campaign_amounts_pos CHECK ((((budget_amount)::numeric >= (0)::numeric) AND ((spent_amount)::numeric >= (0)::numeric))),
    CONSTRAINT chk_campaigns_dates CHECK ((start_date < end_date))
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
    revenue_amount public.money_amount NOT NULL,
    creator_payout_amount public.money_amount NOT NULL,
    currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    impression_type text,
    ad_queue_session_id uuid,
    ad_queue_placement text,
    mcp_tool_call_id uuid,
    CONSTRAINT chk_impressions_amounts_pos CHECK ((((revenue_amount)::numeric >= (0)::numeric) AND ((creator_payout_amount)::numeric >= (0)::numeric)))
);


ALTER TABLE public.ad_impressions OWNER TO postgres;

--
-- Name: ad_queue; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ad_queue (
    chat_session_id uuid NOT NULL,
    ad_id uuid NOT NULL,
    ad_type text NOT NULL,
    placement text NOT NULL,
    similarity numeric(10,8) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    times_served integer DEFAULT 0 NOT NULL,
    initial_similarity numeric(10,8) NOT NULL,
    mcp_tool_call_id uuid,
    CONSTRAINT ad_queue_ad_type_check CHECK ((ad_type = ANY (ARRAY['popup'::text, 'thinking'::text, 'banner'::text, 'video'::text]))),
    CONSTRAINT ad_queue_placement_check CHECK ((placement = ANY (ARRAY['sidebar'::text, 'modal'::text, 'inline'::text, 'overlay'::text, 'header'::text, 'footer'::text, 'default'::text])))
);


ALTER TABLE public.ad_queue OWNER TO postgres;

--
-- Name: TABLE ad_queue; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.ad_queue IS 'Queue for display ads (non-hyperlink) matched to chat sessions via vector similarity';


--
-- Name: COLUMN ad_queue.similarity; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.ad_queue.similarity IS 'Vector similarity score between ad embedding and chat context (0-1)';


--
-- Name: CONSTRAINT ad_queue_placement_check ON ad_queue; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON CONSTRAINT ad_queue_placement_check ON public.ad_queue IS 'Ensures placement is one of the valid values including default';


--
-- Name: ads; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.ads (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid,
    title character varying(255) NOT NULL,
    description text,
    url character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    ad_type public.ad_type DEFAULT 'hyperlink'::public.ad_type NOT NULL,
    pricing_model public.pricing_model DEFAULT 'cpc'::public.pricing_model NOT NULL,
    status public.ad_status DEFAULT 'pending'::public.ad_status NOT NULL,
    image_url character varying(255),
    needs_description boolean DEFAULT false NOT NULL,
    estimated_epc numeric(14,6) DEFAULT 0.00,
    CONSTRAINT banner_ads_image_required CHECK (((ad_type <> 'banner'::public.ad_type) OR (image_url IS NOT NULL)))
);


ALTER TABLE public.ads OWNER TO postgres;

--
-- Name: COLUMN ads.needs_description; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.ads.needs_description IS 'Whether the frontend should display the description field for this ad';


--
-- Name: COLUMN ads.estimated_epc; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.ads.estimated_epc IS 'Estimated earnings per click for this ad in USD';


--
-- Name: advertiser_payments; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.advertiser_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    advertiser_id uuid,
    campaign_id uuid,
    amount public.money_amount NOT NULL,
    currency character(3) NOT NULL,
    external_tx_id character varying(255),
    received_at timestamp with time zone NOT NULL,
    memo text,
    created_at timestamp with time zone DEFAULT now(),
    method text
);


ALTER TABLE public.advertiser_payments OWNER TO postgres;

--
-- Name: advertiser_status_values; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.advertiser_status_values (
    value text NOT NULL
);


ALTER TABLE public.advertiser_status_values OWNER TO postgres;

--
-- Name: advertisers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.advertisers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    status text DEFAULT 'active'::text
);


ALTER TABLE public.advertisers OWNER TO postgres;

--
-- Name: business_ad_type_preferences; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.business_ad_type_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid NOT NULL,
    ad_type character varying(20) NOT NULL,
    is_enabled boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT business_ad_type_preferences_ad_type_check CHECK (((ad_type)::text = ANY ((ARRAY['text'::character varying, 'banner'::character varying, 'video'::character varying, 'hyperlink'::character varying, 'popup'::character varying, 'thinking'::character varying])::text[])))
);


ALTER TABLE public.business_ad_type_preferences OWNER TO postgres;

--
-- Name: business_category_preferences; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.business_category_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid NOT NULL,
    category_id uuid NOT NULL,
    preference character varying(20) DEFAULT 'allowed'::character varying,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT business_category_preferences_preference_check CHECK (((preference)::text = ANY ((ARRAY['preferred'::character varying, 'allowed'::character varying, 'blocked'::character varying])::text[])))
);


ALTER TABLE public.business_category_preferences OWNER TO postgres;

--
-- Name: business_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.business_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid NOT NULL,
    ad_frequency character varying(20) DEFAULT 'normal'::character varying,
    revenue_vs_relevance numeric(3,2) DEFAULT 0.5,
    min_seconds_between_display_ads integer DEFAULT 30,
    display_ad_similarity_threshold numeric(3,2) DEFAULT 0.25,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    CONSTRAINT business_settings_ad_frequency_check CHECK (((ad_frequency)::text = ANY ((ARRAY['low'::character varying, 'normal'::character varying, 'high'::character varying])::text[]))),
    CONSTRAINT business_settings_revenue_vs_relevance_check CHECK (((revenue_vs_relevance >= 0.0) AND (revenue_vs_relevance <= 1.0)))
);


ALTER TABLE public.business_settings OWNER TO postgres;

--
-- Name: campaign_cpc_rates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.campaign_cpc_rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    campaign_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    cpc_rate_amount public.money_amount NOT NULL,
    currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    placement public.ad_placement NOT NULL,
    ad_type public.ad_type NOT NULL
);


ALTER TABLE public.campaign_cpc_rates OWNER TO postgres;

--
-- Name: category_status_values; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.category_status_values (
    value text NOT NULL
);


ALTER TABLE public.category_status_values OWNER TO postgres;

--
-- Name: chat_messages; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.chat_messages (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid,
    message text NOT NULL,
    is_user boolean NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.chat_messages OWNER TO postgres;

--
-- Name: chat_sessions; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.chat_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid,
    visitor_uuid uuid,
    started_at timestamp with time zone DEFAULT now(),
    ended_at timestamp with time zone,
    run_id character varying(255),
    session_type character varying(20) DEFAULT 'mcp'::character varying,
    last_activity_at timestamp with time zone DEFAULT now(),
    ad_frequency character varying(20),
    revenue_vs_relevance numeric(3,2),
    display_ad_similarity_threshold numeric(3,2),
    min_seconds_between_display_ads integer,
    CONSTRAINT chat_sessions_ad_frequency_check CHECK (((ad_frequency)::text = ANY ((ARRAY['low'::character varying, 'normal'::character varying, 'high'::character varying])::text[]))),
    CONSTRAINT chat_sessions_revenue_vs_relevance_check CHECK (((revenue_vs_relevance >= 0.0) AND (revenue_vs_relevance <= 1.0))),
    CONSTRAINT chat_sessions_session_type_check CHECK (((session_type)::text = ANY ((ARRAY['mcp'::character varying, 'direct_chat'::character varying])::text[]))),
    CONSTRAINT chk_sessions_dates CHECK (((ended_at IS NULL) OR (started_at < ended_at)))
);


ALTER TABLE public.chat_sessions OWNER TO postgres;

--
-- Name: content; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.content (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid,
    title character varying(255) NOT NULL,
    content text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    status text DEFAULT 'draft'::text NOT NULL
);


ALTER TABLE public.content OWNER TO postgres;

--
-- Name: content_status_values; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.content_status_values (
    value text NOT NULL
);


ALTER TABLE public.content_status_values OWNER TO postgres;

--
-- Name: creator_advertiser_blocklists; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.creator_advertiser_blocklists (
    creator_id uuid NOT NULL,
    advertiser_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.creator_advertiser_blocklists OWNER TO postgres;

--
-- Name: creator_affiliate_codes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.creator_affiliate_codes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid NOT NULL,
    advertiser_id uuid NOT NULL,
    affiliate_code character varying(255) NOT NULL,
    affiliate_program character varying(100) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    commission_rate numeric(5,4),
    currency character(3) DEFAULT 'USD'::bpchar,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone
);


ALTER TABLE public.creator_affiliate_codes OWNER TO postgres;

--
-- Name: TABLE creator_affiliate_codes; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.creator_affiliate_codes IS 'Stores affiliate codes between creators and advertisers/sponsors for affiliate marketing campaigns';


--
-- Name: COLUMN creator_affiliate_codes.affiliate_code; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.creator_affiliate_codes.affiliate_code IS 'The unique affiliate/tracking code for this creator-advertiser relationship';


--
-- Name: COLUMN creator_affiliate_codes.affiliate_program; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.creator_affiliate_codes.affiliate_program IS 'The affiliate program name (e.g., amazon, clickbank, custom)';


--
-- Name: COLUMN creator_affiliate_codes.is_active; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.creator_affiliate_codes.is_active IS 'Whether this affiliate code is currently active and should be used';


--
-- Name: COLUMN creator_affiliate_codes.commission_rate; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.creator_affiliate_codes.commission_rate IS 'Commission rate as decimal (e.g., 0.05 for 5% commission)';


--
-- Name: creator_campaign_cpc_rates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.creator_campaign_cpc_rates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    cpc_rate_amount public.money_amount NOT NULL,
    currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    placement public.ad_placement NOT NULL,
    ad_type public.ad_type NOT NULL
);


ALTER TABLE public.creator_campaign_cpc_rates OWNER TO postgres;

--
-- Name: creator_category_preferences; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.creator_category_preferences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid,
    category_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    status text DEFAULT 'allowed'::text NOT NULL
);


ALTER TABLE public.creator_category_preferences OWNER TO postgres;

--
-- Name: creator_settings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.creator_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid,
    default_cpc public.money_amount,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone,
    default_category_pref text DEFAULT 'inherit'::text NOT NULL
);


ALTER TABLE public.creator_settings OWNER TO postgres;

--
-- Name: creators; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.creators (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name character varying(255) NOT NULL,
    bio text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
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
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT default_ad_ad_type_check CHECK ((ad_type = ANY (ARRAY['popup'::text, 'thinking'::text, 'banner'::text, 'video'::text]))),
    CONSTRAINT default_ad_global_constraint CHECK ((((is_global_default = true) AND (creator_id IS NULL)) OR ((is_global_default = false) AND (creator_id IS NOT NULL)))),
    CONSTRAINT default_ad_placement_check CHECK ((placement = ANY (ARRAY['sidebar'::text, 'modal'::text, 'inline'::text, 'overlay'::text, 'header'::text, 'footer'::text, 'default'::text])))
);


ALTER TABLE public.default_ad_relationship OWNER TO postgres;

--
-- Name: TABLE default_ad_relationship; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.default_ad_relationship IS 'Default fallback ads with hierarchy: creator-specific defaults override global defaults for the same ad_type/placement';


--
-- Name: COLUMN default_ad_relationship.creator_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.default_ad_relationship.creator_id IS 'NULL for global defaults, specific creator ID for creator defaults';


--
-- Name: COLUMN default_ad_relationship.is_global_default; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.default_ad_relationship.is_global_default IS 'TRUE for system-wide defaults when no creator-specific defaults exist';


--
-- Name: CONSTRAINT default_ad_placement_check ON default_ad_relationship; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON CONSTRAINT default_ad_placement_check ON public.default_ad_relationship IS 'Ensures placement is one of the valid values including default';


--
-- Name: effective_cpc_rates; Type: TABLE; Schema: public; Owner: postgres
--

CREATE UNLOGGED TABLE public.effective_cpc_rates (
    creator_id uuid NOT NULL,
    campaign_id uuid NOT NULL,
    placement public.ad_placement NOT NULL,
    ad_type public.ad_type NOT NULL,
    effective_cpc_rate public.money_amount NOT NULL
);


ALTER TABLE public.effective_cpc_rates OWNER TO postgres;

--
-- Name: embeddings; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.embeddings (
    source_table text NOT NULL,
    source_id uuid NOT NULL,
    embedding public.vector(1536),
    created_at timestamp with time zone DEFAULT now(),
    chunk_id integer NOT NULL,
    CONSTRAINT chk_embeddings_source_table CHECK ((source_table = ANY (ARRAY['content'::text, 'ads'::text])))
);


ALTER TABLE public.embeddings OWNER TO postgres;

--
-- Name: impression_type_values; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.impression_type_values (
    value text NOT NULL
);


ALTER TABLE public.impression_type_values OWNER TO postgres;

--
-- Name: mcp_tool_call_queries; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.mcp_tool_call_queries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mcp_tool_call_id uuid,
    query_text text NOT NULL,
    query_order integer NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT mcp_tool_call_queries_query_order_check CHECK (((query_order >= 1) AND (query_order <= 3)))
);


ALTER TABLE public.mcp_tool_call_queries OWNER TO postgres;

--
-- Name: mcp_tool_calls; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.mcp_tool_calls (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    conversation_id uuid NOT NULL,
    user_message text,
    hyperlink_ads_returned integer DEFAULT 0,
    display_ads_queued integer DEFAULT 0,
    processing_time_ms integer,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.mcp_tool_calls OWNER TO postgres;

--
-- Name: message_ads; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.message_ads (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    message_id uuid,
    ad_id uuid,
    slot integer NOT NULL,
    shown_at timestamp with time zone DEFAULT now(),
    placement public.ad_placement DEFAULT 'default'::public.ad_placement NOT NULL,
    CONSTRAINT chk_message_ads_slot CHECK ((slot > 0))
);


ALTER TABLE public.message_ads OWNER TO postgres;

--
-- Name: notifications; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.notifications (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    type character varying(50) NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    read_at timestamp with time zone
);


ALTER TABLE public.notifications OWNER TO postgres;

--
-- Name: payment_method_values; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payment_method_values (
    value text NOT NULL
);


ALTER TABLE public.payment_method_values OWNER TO postgres;

--
-- Name: payouts; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.payouts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    creator_id uuid,
    amount public.money_amount NOT NULL,
    period_start timestamp with time zone NOT NULL,
    period_end timestamp with time zone NOT NULL,
    status character varying(20) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    currency character(3) DEFAULT 'USD'::bpchar NOT NULL,
    CONSTRAINT chk_payouts_period CHECK ((period_start < period_end))
);


ALTER TABLE public.payouts OWNER TO postgres;

--
-- Name: preference_status_values; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.preference_status_values (
    value text NOT NULL
);


ALTER TABLE public.preference_status_values OWNER TO postgres;

--
-- Name: session_ad_type_overrides; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.session_ad_type_overrides (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    session_id uuid,
    ad_type character varying(20) NOT NULL,
    is_enabled boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT session_ad_type_overrides_ad_type_check CHECK (((ad_type)::text = ANY ((ARRAY['text'::character varying, 'banner'::character varying, 'video'::character varying, 'hyperlink'::character varying, 'popup'::character varying, 'thinking'::character varying])::text[])))
);


ALTER TABLE public.session_ad_type_overrides OWNER TO postgres;

--
-- Name: user_roles; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.user_roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    role text NOT NULL
);


ALTER TABLE public.user_roles OWNER TO postgres;

--
-- Name: users; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    email character varying(255) NOT NULL,
    password_hash character varying(255) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    deleted_at timestamp with time zone
);


ALTER TABLE public.users OWNER TO postgres;

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
-- Name: ad_category_relationships ad_category_relationships_ad_id_category_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_category_relationships
    ADD CONSTRAINT ad_category_relationships_ad_id_category_id_key UNIQUE (ad_id, category_id);


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
-- Name: ad_queue ad_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_queue
    ADD CONSTRAINT ad_queue_pkey PRIMARY KEY (chat_session_id, ad_id, placement);


--
-- Name: ads ads_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ads
    ADD CONSTRAINT ads_pkey PRIMARY KEY (id);


--
-- Name: advertiser_payments advertiser_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.advertiser_payments
    ADD CONSTRAINT advertiser_payments_pkey PRIMARY KEY (id);


--
-- Name: advertiser_status_values advertiser_status_values_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.advertiser_status_values
    ADD CONSTRAINT advertiser_status_values_pkey PRIMARY KEY (value);


--
-- Name: advertisers advertisers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.advertisers
    ADD CONSTRAINT advertisers_pkey PRIMARY KEY (id);


--
-- Name: business_ad_type_preferences business_ad_type_preferences_creator_id_ad_type_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_ad_type_preferences
    ADD CONSTRAINT business_ad_type_preferences_creator_id_ad_type_key UNIQUE (creator_id, ad_type);


--
-- Name: business_ad_type_preferences business_ad_type_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_ad_type_preferences
    ADD CONSTRAINT business_ad_type_preferences_pkey PRIMARY KEY (id);


--
-- Name: business_category_preferences business_category_preferences_creator_id_category_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_category_preferences
    ADD CONSTRAINT business_category_preferences_creator_id_category_id_key UNIQUE (creator_id, category_id);


--
-- Name: business_category_preferences business_category_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_category_preferences
    ADD CONSTRAINT business_category_preferences_pkey PRIMARY KEY (id);


--
-- Name: business_settings business_settings_creator_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_settings
    ADD CONSTRAINT business_settings_creator_id_key UNIQUE (creator_id);


--
-- Name: business_settings business_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_settings
    ADD CONSTRAINT business_settings_pkey PRIMARY KEY (id);


--
-- Name: campaign_cpc_rates campaign_cpc_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.campaign_cpc_rates
    ADD CONSTRAINT campaign_cpc_rates_pkey PRIMARY KEY (id);


--
-- Name: category_status_values category_status_values_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.category_status_values
    ADD CONSTRAINT category_status_values_pkey PRIMARY KEY (value);


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
-- Name: content content_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.content
    ADD CONSTRAINT content_pkey PRIMARY KEY (id);


--
-- Name: content_status_values content_status_values_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.content_status_values
    ADD CONSTRAINT content_status_values_pkey PRIMARY KEY (value);


--
-- Name: creator_advertiser_blocklists creator_advertiser_blocklists_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_advertiser_blocklists
    ADD CONSTRAINT creator_advertiser_blocklists_pkey PRIMARY KEY (creator_id, advertiser_id);


--
-- Name: creator_affiliate_codes creator_affiliate_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_affiliate_codes
    ADD CONSTRAINT creator_affiliate_codes_pkey PRIMARY KEY (id);


--
-- Name: creator_affiliate_codes creator_affiliate_codes_unique_creator_advertiser_program; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_affiliate_codes
    ADD CONSTRAINT creator_affiliate_codes_unique_creator_advertiser_program UNIQUE (creator_id, advertiser_id, affiliate_program);


--
-- Name: creator_campaign_cpc_rates creator_campaign_cpc_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_campaign_cpc_rates
    ADD CONSTRAINT creator_campaign_cpc_rates_pkey PRIMARY KEY (id);


--
-- Name: creator_category_preferences creator_category_preferences_creator_id_category_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_category_preferences
    ADD CONSTRAINT creator_category_preferences_creator_id_category_id_key UNIQUE (creator_id, category_id);


--
-- Name: creator_category_preferences creator_category_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_category_preferences
    ADD CONSTRAINT creator_category_preferences_pkey PRIMARY KEY (id);


--
-- Name: creator_settings creator_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_settings
    ADD CONSTRAINT creator_settings_pkey PRIMARY KEY (id);


--
-- Name: creators creators_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creators
    ADD CONSTRAINT creators_pkey PRIMARY KEY (id);


--
-- Name: default_ad_relationship default_ad_global_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.default_ad_relationship
    ADD CONSTRAINT default_ad_global_unique UNIQUE (ad_type, placement, is_global_default) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: CONSTRAINT default_ad_global_unique ON default_ad_relationship; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON CONSTRAINT default_ad_global_unique ON public.default_ad_relationship IS 'Ensures only one global default per ad_type/placement, while allowing creator-specific overrides';


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
-- Name: effective_cpc_rates effective_cpc_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.effective_cpc_rates
    ADD CONSTRAINT effective_cpc_rates_pkey PRIMARY KEY (creator_id, campaign_id, placement, ad_type);


--
-- Name: embeddings embeddings_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.embeddings
    ADD CONSTRAINT embeddings_pkey PRIMARY KEY (source_table, source_id, chunk_id);


--
-- Name: impression_type_values impression_type_values_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.impression_type_values
    ADD CONSTRAINT impression_type_values_pkey PRIMARY KEY (value);


--
-- Name: mcp_tool_call_queries mcp_tool_call_queries_mcp_tool_call_id_query_order_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mcp_tool_call_queries
    ADD CONSTRAINT mcp_tool_call_queries_mcp_tool_call_id_query_order_key UNIQUE (mcp_tool_call_id, query_order);


--
-- Name: mcp_tool_call_queries mcp_tool_call_queries_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mcp_tool_call_queries
    ADD CONSTRAINT mcp_tool_call_queries_pkey PRIMARY KEY (id);


--
-- Name: mcp_tool_calls mcp_tool_calls_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mcp_tool_calls
    ADD CONSTRAINT mcp_tool_calls_pkey PRIMARY KEY (id);


--
-- Name: message_ads message_ads_message_id_ad_id_placement_slot_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.message_ads
    ADD CONSTRAINT message_ads_message_id_ad_id_placement_slot_key UNIQUE (message_id, ad_id, placement, slot);


--
-- Name: message_ads message_ads_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.message_ads
    ADD CONSTRAINT message_ads_pkey PRIMARY KEY (id);


--
-- Name: message_ads message_ads_unique_slot_per_message; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.message_ads
    ADD CONSTRAINT message_ads_unique_slot_per_message UNIQUE (message_id, placement, slot);


--
-- Name: notifications notifications_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_pkey PRIMARY KEY (id);


--
-- Name: payment_method_values payment_method_values_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payment_method_values
    ADD CONSTRAINT payment_method_values_pkey PRIMARY KEY (value);


--
-- Name: payouts payouts_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payouts
    ADD CONSTRAINT payouts_pkey PRIMARY KEY (id);


--
-- Name: preference_status_values preference_status_values_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.preference_status_values
    ADD CONSTRAINT preference_status_values_pkey PRIMARY KEY (value);


--
-- Name: session_ad_type_overrides session_ad_type_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.session_ad_type_overrides
    ADD CONSTRAINT session_ad_type_overrides_pkey PRIMARY KEY (id);


--
-- Name: session_ad_type_overrides session_ad_type_overrides_session_id_ad_type_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.session_ad_type_overrides
    ADD CONSTRAINT session_ad_type_overrides_session_id_ad_type_key UNIQUE (session_id, ad_type);


--
-- Name: user_roles user_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: ad_campaigns_name_unique_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX ad_campaigns_name_unique_idx ON public.ad_campaigns USING btree (name) WHERE (deleted_at IS NULL);


--
-- Name: ad_categories_name_unique_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX ad_categories_name_unique_idx ON public.ad_categories USING btree (name);


--
-- Name: ad_impressions_queue_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX ad_impressions_queue_idx ON public.ad_impressions USING btree (ad_queue_session_id, ad_id, ad_queue_placement);


--
-- Name: ad_queue_available_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX ad_queue_available_idx ON public.ad_queue USING btree (chat_session_id, ad_type, placement, similarity DESC);


--
-- Name: ad_queue_times_served_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX ad_queue_times_served_idx ON public.ad_queue USING btree (times_served, similarity DESC);


--
-- Name: advertisers_name_unique_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX advertisers_name_unique_idx ON public.advertisers USING btree (name) WHERE (deleted_at IS NULL);


--
-- Name: creators_name_unique_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX creators_name_unique_idx ON public.creators USING btree (name);


--
-- Name: default_ad_creator_lookup_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX default_ad_creator_lookup_idx ON public.default_ad_relationship USING btree (creator_id, ad_type, placement) WHERE (creator_id IS NOT NULL);


--
-- Name: default_ad_global_lookup_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX default_ad_global_lookup_idx ON public.default_ad_relationship USING btree (ad_type, placement) WHERE (is_global_default = true);


--
-- Name: idx_ad_campaigns_advertiser_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ad_campaigns_advertiser_status ON public.ad_campaigns USING btree (advertiser_id, status) WHERE (deleted_at IS NULL);


--
-- Name: idx_ad_category_relationships_ad_cat; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ad_category_relationships_ad_cat ON public.ad_category_relationships USING btree (ad_id, category_id);


--
-- Name: idx_ad_clicks_billed_status; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ad_clicks_billed_status ON public.ad_clicks USING btree (impression_id, is_billed, created_at);


--
-- Name: idx_ad_clicks_impression_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ad_clicks_impression_created ON public.ad_clicks USING btree (impression_id, created_at);


--
-- Name: idx_ad_clicks_one_billed_per_impression; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_ad_clicks_one_billed_per_impression ON public.ad_clicks USING btree (impression_id) WHERE (is_billed = true);


--
-- Name: INDEX idx_ad_clicks_one_billed_per_impression; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON INDEX public.idx_ad_clicks_one_billed_per_impression IS 'Ensures only one click per impression can be marked as billed for CPC campaigns';


--
-- Name: idx_ad_impressions_ad; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ad_impressions_ad ON public.ad_impressions USING btree (ad_id);


--
-- Name: idx_ad_impressions_creator; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ad_impressions_creator ON public.ad_impressions USING btree (creator_id);


--
-- Name: idx_ad_impressions_creator_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ad_impressions_creator_created ON public.ad_impressions USING btree (creator_id, created_at);


--
-- Name: idx_ads_campaign; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_ads_campaign ON public.ads USING btree (campaign_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_advertiser_payments_advertiser; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_advertiser_payments_advertiser ON public.advertiser_payments USING btree (advertiser_id);


--
-- Name: idx_advertiser_payments_campaign; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_advertiser_payments_campaign ON public.advertiser_payments USING btree (campaign_id);


--
-- Name: idx_advertiser_payments_received; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_advertiser_payments_received ON public.advertiser_payments USING btree (received_at DESC);


--
-- Name: idx_business_ad_type_preferences_creator_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_business_ad_type_preferences_creator_id ON public.business_ad_type_preferences USING btree (creator_id);


--
-- Name: idx_business_ad_type_preferences_enabled; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_business_ad_type_preferences_enabled ON public.business_ad_type_preferences USING btree (creator_id, is_enabled);


--
-- Name: idx_business_category_preferences_creator_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_business_category_preferences_creator_id ON public.business_category_preferences USING btree (creator_id);


--
-- Name: idx_business_category_preferences_preference; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_business_category_preferences_preference ON public.business_category_preferences USING btree (creator_id, preference);


--
-- Name: idx_business_settings_creator_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_business_settings_creator_id ON public.business_settings USING btree (creator_id);


--
-- Name: idx_business_settings_is_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_business_settings_is_active ON public.business_settings USING btree (is_active);


--
-- Name: idx_campaign_cpc_rates_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_campaign_cpc_rates_lookup ON public.campaign_cpc_rates USING btree (campaign_id, placement, ad_type);


--
-- Name: idx_campaigns_name_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_campaigns_name_active ON public.ad_campaigns USING btree (name) WHERE (deleted_at IS NULL);


--
-- Name: idx_chat_messages_session_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_chat_messages_session_created ON public.chat_messages USING btree (session_id, created_at);


--
-- Name: idx_chat_sessions_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_chat_sessions_active ON public.chat_sessions USING btree (creator_id, visitor_uuid) WHERE (ended_at IS NULL);


--
-- Name: idx_chat_sessions_creator_activity; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_chat_sessions_creator_activity ON public.chat_sessions USING btree (creator_id, last_activity_at);


--
-- Name: idx_chat_sessions_creator_started; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_chat_sessions_creator_started ON public.chat_sessions USING btree (creator_id, started_at);


--
-- Name: idx_chat_sessions_creator_visitor; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_chat_sessions_creator_visitor ON public.chat_sessions USING btree (creator_id, visitor_uuid) WHERE (ended_at IS NULL);


--
-- Name: idx_chat_sessions_last_activity; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_chat_sessions_last_activity ON public.chat_sessions USING btree (last_activity_at);


--
-- Name: idx_chat_sessions_run_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_chat_sessions_run_id ON public.chat_sessions USING btree (run_id);


--
-- Name: idx_chat_sessions_session_type; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_chat_sessions_session_type ON public.chat_sessions USING btree (session_type);


--
-- Name: idx_content_creator; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_content_creator ON public.content USING btree (creator_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_creator_affiliate_codes_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_affiliate_codes_active ON public.creator_affiliate_codes USING btree (creator_id, advertiser_id);


--
-- Name: idx_creator_affiliate_codes_advertiser; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_affiliate_codes_advertiser ON public.creator_affiliate_codes USING btree (advertiser_id);


--
-- Name: idx_creator_affiliate_codes_advertiser_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_affiliate_codes_advertiser_active ON public.creator_affiliate_codes USING btree (advertiser_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_creator_affiliate_codes_creator; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_affiliate_codes_creator ON public.creator_affiliate_codes USING btree (creator_id);


--
-- Name: idx_creator_affiliate_codes_creator_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_affiliate_codes_creator_active ON public.creator_affiliate_codes USING btree (creator_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_creator_affiliate_codes_creator_advertiser_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_affiliate_codes_creator_advertiser_active ON public.creator_affiliate_codes USING btree (creator_id, advertiser_id) WHERE ((is_active = true) AND (deleted_at IS NULL));


--
-- Name: idx_creator_campaign_cpc_rates_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_campaign_cpc_rates_lookup ON public.creator_campaign_cpc_rates USING btree (creator_id, campaign_id, placement, ad_type);


--
-- Name: idx_creator_category_prefs_category; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_category_prefs_category ON public.creator_category_preferences USING btree (category_id);


--
-- Name: idx_creator_category_prefs_creator; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_category_prefs_creator ON public.creator_category_preferences USING btree (creator_id);


--
-- Name: idx_creator_category_prefs_creator_cat; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_category_prefs_creator_cat ON public.creator_category_preferences USING btree (creator_id, category_id);


--
-- Name: idx_creator_settings_creator; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_creator_settings_creator ON public.creator_settings USING btree (creator_id) WHERE (deleted_at IS NULL);


--
-- Name: idx_embeddings_ann; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_embeddings_ann ON public.embeddings USING ivfflat (embedding public.vector_cosine_ops) WITH (lists='100');


--
-- Name: idx_embeddings_embedding; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_embeddings_embedding ON public.embeddings USING ivfflat (embedding) WITH (lists='100');


--
-- Name: idx_mcp_tool_call_queries_tool_call_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_mcp_tool_call_queries_tool_call_id ON public.mcp_tool_call_queries USING btree (mcp_tool_call_id);


--
-- Name: idx_mcp_tool_calls_conversation_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_mcp_tool_calls_conversation_id ON public.mcp_tool_calls USING btree (conversation_id);


--
-- Name: idx_mcp_tool_calls_created_at; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_mcp_tool_calls_created_at ON public.mcp_tool_calls USING btree (created_at);


--
-- Name: idx_message_ads_ad; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_message_ads_ad ON public.message_ads USING btree (ad_id);


--
-- Name: idx_notifications_user_created; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_user_created ON public.notifications USING btree (user_id, created_at);


--
-- Name: idx_notifications_user_unread; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_notifications_user_unread ON public.notifications USING btree (user_id, read_at) WHERE (read_at IS NULL);


--
-- Name: idx_payouts_creator; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_payouts_creator ON public.payouts USING btree (creator_id);


--
-- Name: idx_payouts_creator_period; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_payouts_creator_period ON public.payouts USING btree (creator_id, period_start, period_end);


--
-- Name: idx_session_ad_type_overrides_enabled; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_session_ad_type_overrides_enabled ON public.session_ad_type_overrides USING btree (session_id, is_enabled);


--
-- Name: idx_session_ad_type_overrides_session_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_session_ad_type_overrides_session_id ON public.session_ad_type_overrides USING btree (session_id);


--
-- Name: idx_users_email; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_users_email ON public.users USING btree (email) WHERE (deleted_at IS NULL);


--
-- Name: idx_users_email_active; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX idx_users_email_active ON public.users USING btree (email) WHERE (deleted_at IS NULL);


--
-- Name: creator_affiliate_codes refresh_cpc_rates_on_creator_affiliate_codes; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER refresh_cpc_rates_on_creator_affiliate_codes AFTER INSERT OR DELETE OR UPDATE ON public.creator_affiliate_codes FOR EACH ROW EXECUTE FUNCTION public.trigger_refresh_effective_cpc_rates();


--
-- Name: ad_impressions sync_campaign_spent_on_impression; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER sync_campaign_spent_on_impression AFTER INSERT ON public.ad_impressions FOR EACH ROW EXECUTE FUNCTION public.sync_campaign_spent_and_status();


--
-- Name: ads trg_ads_campaign_active; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE CONSTRAINT TRIGGER trg_ads_campaign_active AFTER INSERT OR UPDATE OF status, campaign_id ON public.ads DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.enforce_campaign_active_for_ads();


--
-- Name: embeddings trg_embeddings_source_fk; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE CONSTRAINT TRIGGER trg_embeddings_source_fk AFTER INSERT OR UPDATE OF source_table, source_id ON public.embeddings DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.validate_embeddings_source_fk();


--
-- Name: ad_campaigns update_ad_campaigns_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_ad_campaigns_updated_at BEFORE UPDATE ON public.ad_campaigns FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: ad_impressions update_ad_impressions_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_ad_impressions_updated_at BEFORE UPDATE ON public.ad_impressions FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: ads update_ads_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_ads_updated_at BEFORE UPDATE ON public.ads FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: advertisers update_advertisers_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_advertisers_updated_at BEFORE UPDATE ON public.advertisers FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: content update_content_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_content_updated_at BEFORE UPDATE ON public.content FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: creator_affiliate_codes update_creator_affiliate_codes_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_creator_affiliate_codes_updated_at BEFORE UPDATE ON public.creator_affiliate_codes FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: creator_category_preferences update_creator_category_prefs_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_creator_category_prefs_updated_at BEFORE UPDATE ON public.creator_category_preferences FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: creator_settings update_creator_settings_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_creator_settings_updated_at BEFORE UPDATE ON public.creator_settings FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: creators update_creators_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_creators_updated_at BEFORE UPDATE ON public.creators FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: default_ad_relationship update_default_ad_relationship_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_default_ad_relationship_updated_at BEFORE UPDATE ON public.default_ad_relationship FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: payouts update_payouts_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_payouts_updated_at BEFORE UPDATE ON public.payouts FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: users update_users_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: ad_campaigns ad_campaigns_advertiser_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_campaigns
    ADD CONSTRAINT ad_campaigns_advertiser_id_fkey FOREIGN KEY (advertiser_id) REFERENCES public.advertisers(id) ON DELETE CASCADE;


--
-- Name: ad_category_relationships ad_category_relationships_ad_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_category_relationships
    ADD CONSTRAINT ad_category_relationships_ad_id_fkey FOREIGN KEY (ad_id) REFERENCES public.ads(id) ON DELETE CASCADE;


--
-- Name: ad_category_relationships ad_category_relationships_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_category_relationships
    ADD CONSTRAINT ad_category_relationships_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.ad_categories(id) ON DELETE CASCADE;


--
-- Name: ad_clicks ad_clicks_impression_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_clicks
    ADD CONSTRAINT ad_clicks_impression_id_fkey FOREIGN KEY (impression_id) REFERENCES public.ad_impressions(id) ON DELETE CASCADE;


--
-- Name: ad_impressions ad_impressions_ad_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_ad_id_fkey FOREIGN KEY (ad_id) REFERENCES public.ads(id) ON DELETE SET NULL;


--
-- Name: ad_impressions ad_impressions_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE SET NULL;


--
-- Name: ad_impressions ad_impressions_impression_type_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_impression_type_fk FOREIGN KEY (impression_type) REFERENCES public.impression_type_values(value);


--
-- Name: ad_impressions ad_impressions_mcp_tool_call_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_mcp_tool_call_id_fkey FOREIGN KEY (mcp_tool_call_id) REFERENCES public.mcp_tool_calls(id);


--
-- Name: ad_impressions ad_impressions_message_ad_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_message_ad_id_fkey FOREIGN KEY (message_ad_id) REFERENCES public.message_ads(id) ON DELETE SET NULL;


--
-- Name: ad_impressions ad_impressions_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT ad_impressions_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.chat_sessions(id);


--
-- Name: ad_queue ad_queue_ad_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_queue
    ADD CONSTRAINT ad_queue_ad_id_fkey FOREIGN KEY (ad_id) REFERENCES public.ads(id) ON DELETE CASCADE;


--
-- Name: ad_queue ad_queue_chat_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_queue
    ADD CONSTRAINT ad_queue_chat_session_id_fkey FOREIGN KEY (chat_session_id) REFERENCES public.chat_sessions(id) ON DELETE CASCADE;


--
-- Name: ad_queue ad_queue_mcp_tool_call_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_queue
    ADD CONSTRAINT ad_queue_mcp_tool_call_id_fkey FOREIGN KEY (mcp_tool_call_id) REFERENCES public.mcp_tool_calls(id);


--
-- Name: ads ads_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ads
    ADD CONSTRAINT ads_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.ad_campaigns(id) ON DELETE CASCADE;


--
-- Name: advertiser_payments advertiser_payments_advertiser_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.advertiser_payments
    ADD CONSTRAINT advertiser_payments_advertiser_id_fkey FOREIGN KEY (advertiser_id) REFERENCES public.advertisers(id) ON DELETE CASCADE;


--
-- Name: advertiser_payments advertiser_payments_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.advertiser_payments
    ADD CONSTRAINT advertiser_payments_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.ad_campaigns(id) ON DELETE CASCADE;


--
-- Name: advertiser_payments advertiser_payments_method_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.advertiser_payments
    ADD CONSTRAINT advertiser_payments_method_fk FOREIGN KEY (method) REFERENCES public.payment_method_values(value);


--
-- Name: advertisers advertisers_status_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.advertisers
    ADD CONSTRAINT advertisers_status_fk FOREIGN KEY (status) REFERENCES public.advertiser_status_values(value);


--
-- Name: advertisers advertisers_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.advertisers
    ADD CONSTRAINT advertisers_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: business_ad_type_preferences business_ad_type_preferences_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_ad_type_preferences
    ADD CONSTRAINT business_ad_type_preferences_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id);


--
-- Name: business_category_preferences business_category_preferences_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_category_preferences
    ADD CONSTRAINT business_category_preferences_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.ad_categories(id);


--
-- Name: business_category_preferences business_category_preferences_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_category_preferences
    ADD CONSTRAINT business_category_preferences_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id);


--
-- Name: business_settings business_settings_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.business_settings
    ADD CONSTRAINT business_settings_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id);


--
-- Name: campaign_cpc_rates campaign_cpc_rates_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.campaign_cpc_rates
    ADD CONSTRAINT campaign_cpc_rates_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.ad_campaigns(id) ON DELETE CASCADE;


--
-- Name: chat_messages chat_messages_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chat_messages
    ADD CONSTRAINT chat_messages_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.chat_sessions(id) ON DELETE CASCADE;


--
-- Name: chat_sessions chat_sessions_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.chat_sessions
    ADD CONSTRAINT chat_sessions_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE CASCADE;


--
-- Name: content content_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.content
    ADD CONSTRAINT content_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE CASCADE;


--
-- Name: content content_status_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.content
    ADD CONSTRAINT content_status_fk FOREIGN KEY (status) REFERENCES public.content_status_values(value);


--
-- Name: creator_advertiser_blocklists creator_advertiser_blocklists_advertiser_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_advertiser_blocklists
    ADD CONSTRAINT creator_advertiser_blocklists_advertiser_id_fkey FOREIGN KEY (advertiser_id) REFERENCES public.advertisers(id) ON DELETE CASCADE;


--
-- Name: creator_advertiser_blocklists creator_advertiser_blocklists_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_advertiser_blocklists
    ADD CONSTRAINT creator_advertiser_blocklists_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE CASCADE;


--
-- Name: creator_affiliate_codes creator_affiliate_codes_advertiser_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_affiliate_codes
    ADD CONSTRAINT creator_affiliate_codes_advertiser_id_fkey FOREIGN KEY (advertiser_id) REFERENCES public.advertisers(id) ON DELETE CASCADE;


--
-- Name: creator_affiliate_codes creator_affiliate_codes_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_affiliate_codes
    ADD CONSTRAINT creator_affiliate_codes_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE CASCADE;


--
-- Name: creator_campaign_cpc_rates creator_campaign_cpc_rates_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_campaign_cpc_rates
    ADD CONSTRAINT creator_campaign_cpc_rates_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.ad_campaigns(id) ON DELETE CASCADE;


--
-- Name: creator_campaign_cpc_rates creator_campaign_cpc_rates_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_campaign_cpc_rates
    ADD CONSTRAINT creator_campaign_cpc_rates_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE CASCADE;


--
-- Name: creator_category_preferences creator_category_preferences_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_category_preferences
    ADD CONSTRAINT creator_category_preferences_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.ad_categories(id) ON DELETE CASCADE;


--
-- Name: creator_category_preferences creator_category_preferences_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_category_preferences
    ADD CONSTRAINT creator_category_preferences_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE CASCADE;


--
-- Name: creator_category_preferences creator_category_preferences_status_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_category_preferences
    ADD CONSTRAINT creator_category_preferences_status_fk FOREIGN KEY (status) REFERENCES public.preference_status_values(value);


--
-- Name: creator_settings creator_settings_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_settings
    ADD CONSTRAINT creator_settings_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE CASCADE;


--
-- Name: creator_settings creator_settings_default_category_pref_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creator_settings
    ADD CONSTRAINT creator_settings_default_category_pref_fk FOREIGN KEY (default_category_pref) REFERENCES public.category_status_values(value);


--
-- Name: creators creators_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.creators
    ADD CONSTRAINT creators_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: default_ad_relationship default_ad_relationship_ad_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.default_ad_relationship
    ADD CONSTRAINT default_ad_relationship_ad_id_fkey FOREIGN KEY (ad_id) REFERENCES public.ads(id) ON DELETE CASCADE;


--
-- Name: default_ad_relationship default_ad_relationship_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.default_ad_relationship
    ADD CONSTRAINT default_ad_relationship_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE CASCADE;


--
-- Name: ad_impressions fk_ad_impressions_queue; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.ad_impressions
    ADD CONSTRAINT fk_ad_impressions_queue FOREIGN KEY (ad_queue_session_id, ad_id, ad_queue_placement) REFERENCES public.ad_queue(chat_session_id, ad_id, placement) ON DELETE SET NULL;


--
-- Name: mcp_tool_call_queries mcp_tool_call_queries_mcp_tool_call_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mcp_tool_call_queries
    ADD CONSTRAINT mcp_tool_call_queries_mcp_tool_call_id_fkey FOREIGN KEY (mcp_tool_call_id) REFERENCES public.mcp_tool_calls(id) ON DELETE CASCADE;


--
-- Name: mcp_tool_calls mcp_tool_calls_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.mcp_tool_calls
    ADD CONSTRAINT mcp_tool_calls_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES public.chat_sessions(id);


--
-- Name: message_ads message_ads_ad_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.message_ads
    ADD CONSTRAINT message_ads_ad_id_fkey FOREIGN KEY (ad_id) REFERENCES public.ads(id) ON DELETE CASCADE;


--
-- Name: message_ads message_ads_message_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.message_ads
    ADD CONSTRAINT message_ads_message_id_fkey FOREIGN KEY (message_id) REFERENCES public.chat_messages(id) ON DELETE CASCADE;


--
-- Name: notifications notifications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.notifications
    ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: payouts payouts_creator_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.payouts
    ADD CONSTRAINT payouts_creator_id_fkey FOREIGN KEY (creator_id) REFERENCES public.creators(id) ON DELETE CASCADE;


--
-- Name: session_ad_type_overrides session_ad_type_overrides_session_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.session_ad_type_overrides
    ADD CONSTRAINT session_ad_type_overrides_session_id_fkey FOREIGN KEY (session_id) REFERENCES public.chat_sessions(id) ON DELETE CASCADE;


--
-- Name: user_roles user_roles_role_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_role_fk FOREIGN KEY (role) REFERENCES public.account_role_values(value);


--
-- Name: user_roles user_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.user_roles
    ADD CONSTRAINT user_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

