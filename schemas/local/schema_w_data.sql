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
-- Data for Name: account_role_values; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.account_role_values (value) FROM stdin;
admin
creator
advertiser
\.


--
-- Data for Name: ad_campaigns; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ad_campaigns (id, advertiser_id, name, start_date, end_date, created_at, updated_at, deleted_at, budget_amount, spent_amount, currency, status, time_zone) FROM stdin;
406ef64f-f508-4764-a8e3-94e92abe3c0a	f84e9ba6-2b4c-47a5-a887-d5cf21e8f83d	TestAdvertiser1_TestCampaign1	2025-07-19 08:23:46.295529-04	2026-07-19 08:23:46.295529-04	2025-07-19 08:23:46.287544-04	2025-07-19 08:23:46.287544-04	\N	1.000000	0.000000	USD	active	UTC
273d4140-65cd-42d5-955b-8f974ecac053	4d3c5113-acb2-4a71-a8c0-6eaea5cc57bb	TestAdvertiser2_TestCampaign2	2025-07-19 08:23:46.381533-04	2026-07-19 08:23:46.381533-04	2025-07-19 08:23:46.287544-04	2025-07-19 08:23:46.287544-04	\N	1.000000	0.000000	USD	active	UTC
c8eabc10-a90d-439c-9e58-fd9582c0e7f3	ed6822db-9052-4c76-8fd2-726115bd8c8a	WonderShare_cj_aff	2025-07-19 08:31:36.30873-04	2026-07-19 08:31:36.30873-04	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	1.000000	0.000000	USD	active	UTC
cb0c2f3b-913f-49a8-8560-2e5780551850	7b75b21e-9216-4903-ae81-33d28221f899	NordVPN_cj_aff	2025-07-19 08:31:36.382731-04	2026-07-19 08:31:36.382731-04	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	1.000000	0.000000	USD	active	UTC
a0cb719f-486d-4c6a-a981-b4a52b8f805e	f1448859-c289-4faa-929e-595f1da1d564	Acronis_cj_aff	2025-07-19 08:31:36.40673-04	2026-07-19 08:31:36.40673-04	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	1.000000	0.000000	USD	active	UTC
f735a55b-288e-4c4f-b49a-deed34f92f2c	17ca8f14-7ec8-4996-9012-c1c12ef37fb7	Amazon Affiliate_amzn_aff	2025-07-19 08:31:36.42173-04	2026-07-19 08:31:36.42173-04	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	1.000000	0.000000	USD	active	UTC
e6cb7d7e-3b67-42be-8849-d16f6c135844	a35ffde4-c737-40c6-90f4-67b3d50fe966	TestAdvertiser_TestCampaign	2025-07-19 08:32:47.867233-04	2026-07-19 08:32:47.867233-04	2025-07-19 08:32:47.867233-04	2025-07-19 08:32:47.867233-04	\N	100.000000	0.000000	USD	active	UTC
8f170d7b-17ab-4245-8e99-8e010e335384	8a350d79-e678-40c1-b6eb-c765e1525eee	TestAdv_5195ec8a_TestCampaign	2025-07-19 08:35:21.935851-04	2026-07-19 08:35:21.935851-04	2025-07-19 08:35:21.935851-04	2025-07-19 08:35:21.935851-04	\N	100.000000	0.000000	USD	active	UTC
5daa5906-1ba6-4831-9fba-320eec7b910c	ed6822db-9052-4c76-8fd2-726115bd8c8a	Amazon Tech Products Affiliate	2025-07-23 15:19:11.401648-04	2026-07-23 15:19:11.401648-04	2025-07-23 15:19:11.401648-04	2025-07-23 15:19:11.401648-04	\N	1000.000000	0.000000	USD	active	UTC
f46fce08-791e-46ed-94d4-6baba2bfb9ea	ed6822db-9052-4c76-8fd2-726115bd8c8a	Test Affiliate Campaign	2025-07-23 15:32:34.50809-04	2026-07-23 15:32:34.50809-04	2025-07-23 15:32:34.50809-04	2025-07-23 15:32:34.50809-04	\N	1000.000000	0.000000	USD	active	UTC
95df4760-66b1-4d0a-9265-a9cbdc275a56	20dc13ff-1a11-4d00-85c2-40fbb8626333	TechCorp_Summer Sale	2025-08-06 10:23:30.444561-04	2026-08-06 10:23:30.444561-04	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	1.000000	0.000000	USD	active	UTC
a5557f22-1736-4784-93e7-0a0ab5dc0adc	3fd615a3-4bcb-4c9a-825b-c74f02244bbd	BookStore_Reading Month	2025-08-06 10:23:31.561463-04	2026-08-06 10:23:31.561463-04	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	1.000000	0.000000	USD	active	UTC
983cd0ff-83b5-4c9f-ae14-96d8296eb30c	a13ebacd-97c7-492d-9202-5bd25682f7b8	SoftwareCorp_Developer Tools	2025-08-06 10:23:32.396886-04	2026-08-06 10:23:32.396886-04	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	1.000000	0.000000	USD	active	UTC
a2d44548-c7d3-4b13-81a0-91abe15878bd	d1609d19-277d-461c-96ae-b7365d4cd1e6	TestCorp_Test Campaign	2025-08-06 10:23:33.159845-04	2026-08-06 10:23:33.159845-04	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	1.000000	0.000000	USD	active	UTC
eae4c673-093e-40ba-8750-1866791716a0	afca040b-e824-40cb-94ba-2f87bf9d990d	Instantly AI_Instantly_Direct_Aff	2025-08-06 17:10:55.92425-04	2026-08-06 17:10:55.92425-04	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	\N	1.000000	0.000000	USD	active	UTC
a9202906-7dfa-4b7c-8cad-dc47b20f6106	30ef66aa-1fdd-4fb3-8e58-478244d492dc	Shopify_Shopify_Direct_Aff	2025-08-06 17:11:01.581583-04	2026-08-06 17:11:01.581583-04	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	\N	1.000000	0.000000	USD	active	UTC
\.


--
-- Data for Name: ad_categories; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ad_categories (id, name, description, created_at, updated_at) FROM stdin;
ec2a5375-c6ed-4c5f-b95f-5802250893a6	AI Tools	Artificial intelligence and machine-learning software	2025-06-22 09:32:24.359603-04	2025-06-22 09:32:24.359603-04
d9c158af-410d-4992-9c6e-34b4c0ac0e17	Developer Tools	APIs, SDKs, and developer productivity platforms	2025-06-22 09:32:24.359603-04	2025-06-22 09:32:24.359603-04
3571f043-2f22-482f-95cc-19a722652e4d	Productivity	Task management, note-taking, and workflow apps	2025-06-22 09:32:24.359603-04	2025-06-22 09:32:24.359603-04
33f86a4c-ae53-4620-9388-e514fd074fbf	Marketing Tech	Email, social, and growth-automation solutions	2025-06-22 09:32:24.359603-04	2025-06-22 09:32:24.359603-04
ade30c7c-2a36-4cf3-8669-247780fa9abb	Analytics	Product and business-intelligence platforms	2025-06-22 09:32:24.359603-04	2025-06-22 09:32:24.359603-04
7a41daae-5196-4824-8e14-2a3bbe8f5066	Cloud Services	Hosting, infrastructure, and DevOps tooling	2025-06-22 09:32:24.359603-04	2025-06-22 09:32:24.359603-04
eb61c5ec-8c5d-405a-9bbb-9d670f194b15	No-code	Visual app builders and automation without code	2025-06-22 09:32:24.359603-04	2025-06-22 09:32:24.359603-04
2595f21a-cce6-4eae-91f0-cb2e439cbd65	Security	Application and data-security solutions	2025-06-22 09:32:24.359603-04	2025-06-22 09:32:24.359603-04
\.


--
-- Data for Name: ad_category_relationships; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ad_category_relationships (id, ad_id, category_id, created_at) FROM stdin;
\.


--
-- Data for Name: ad_clicks; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ad_clicks (id, impression_id, click_metadata, created_at, is_billed) FROM stdin;
5acfe2a6-6171-4544-a815-8162fda79165	e82b7ae9-59f3-4108-af00-fcafc5ccaa02	{"referer": null, "timestamp": null, "ip_address": "127.0.0.1", "user_agent": "curl/8.9.1"}	2025-07-04 12:02:03.870348-04	t
2b36260f-5814-4b97-bae2-2691a9894c3e	e82b7ae9-59f3-4108-af00-fcafc5ccaa02	{"referer": null, "timestamp": null, "ip_address": "127.0.0.1", "user_agent": "curl/8.9.1"}	2025-07-04 12:02:32.14894-04	f
500d2af8-2165-45ff-b738-af76bd50ea20	e82b7ae9-59f3-4108-af00-fcafc5ccaa02	{"referer": null, "timestamp": null, "ip_address": "127.0.0.1", "user_agent": "curl/8.9.1"}	2025-07-04 12:03:18.85406-04	f
798d4ef4-0217-4ebf-a2f9-fca84a4c1d39	e82b7ae9-59f3-4108-af00-fcafc5ccaa02	{"referer": null, "timestamp": null, "ip_address": "127.0.0.1", "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"}	2025-07-04 12:13:31.462712-04	f
\.


--
-- Data for Name: ad_impressions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ad_impressions (id, message_ad_id, ad_id, creator_id, created_at, updated_at, session_id, status, revenue_amount, creator_payout_amount, currency, impression_type, ad_queue_session_id, ad_queue_placement, mcp_tool_call_id) FROM stdin;
5c6e6b3b-f0d9-48c1-a724-e87329e56576	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 11:46:12.351225-04	2025-07-18 17:51:43.54728-04	52a822c1-1945-4a39-9d1f-18cf060c5168	completed	1.000000	0.700000	USD	\N	\N	\N	\N
40bdcc09-ec35-438d-9470-da3ddde4b32b	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:15:33.134886-04	2025-07-18 17:51:43.54728-04	b3a30668-1a87-4a6c-bb2d-d80a50414b97	completed	1.000000	0.700000	USD	\N	\N	\N	\N
8426dc74-ec1a-4e5f-a75f-da2119d70c15	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:15:41.646552-04	2025-07-18 17:51:43.54728-04	64ece526-953c-4974-8948-f74e87cadda6	completed	1.000000	0.700000	USD	\N	\N	\N	\N
07fee679-41fe-4385-b0d5-c926b1174a68	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:34:49.697949-04	2025-07-18 17:51:43.54728-04	2ce1e6ac-d82e-49df-b59d-a3fe7ff861ce	completed	1.000000	0.700000	USD	\N	\N	\N	\N
de157949-cc69-42e9-b47c-f80d977cb245	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:35:00.064521-04	2025-07-18 17:51:43.54728-04	89839bcf-5ea7-44e4-9b6b-e440fa32e131	completed	1.000000	0.700000	USD	\N	\N	\N	\N
a212192c-4565-4c19-912c-86ab8d4be26f	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:38:49.150873-04	2025-07-18 17:51:43.54728-04	67c9565b-67ff-4a3a-b2c5-05ee9207b54b	completed	1.000000	0.700000	USD	\N	\N	\N	\N
0cf936ff-2611-449e-b949-2e9f1bf533e0	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:38:59.397805-04	2025-07-18 17:51:43.54728-04	ff28a9da-ec91-42b6-9eb1-80bcb0d5c702	completed	1.000000	0.700000	USD	\N	\N	\N	\N
347374b1-cb05-4404-99ba-86e07cf8e47f	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:41:08.269203-04	2025-07-18 17:51:43.54728-04	8bb7b0a9-96d2-487f-9b52-4599fc9fbb79	completed	1.000000	0.700000	USD	\N	\N	\N	\N
60489341-53ab-4adf-8bff-379fc85bbb09	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:41:18.281545-04	2025-07-18 17:51:43.54728-04	19841b52-0d7e-4a14-a709-7349f33bf1a3	completed	1.000000	0.700000	USD	\N	\N	\N	\N
ffe15944-289b-4439-9143-8a97c3aadc2c	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 11:46:12.398275-04	2025-07-18 17:51:43.54728-04	52a822c1-1945-4a39-9d1f-18cf060c5168	completed	1.000000	0.700000	USD	\N	\N	\N	\N
606c0ba6-d708-4749-bb02-195eace34f0f	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:15:33.213135-04	2025-07-18 17:51:43.54728-04	b3a30668-1a87-4a6c-bb2d-d80a50414b97	completed	1.000000	0.700000	USD	\N	\N	\N	\N
be8f00a2-638a-4ca8-adae-140adc8728d4	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:16:05.321086-04	2025-07-18 17:51:43.54728-04	ae7e9937-6716-484b-ad27-6372be336e62	completed	1.000000	0.700000	USD	\N	\N	\N	\N
a4f1de2b-6eeb-4208-ae3b-23a5c44e2606	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:34:49.74346-04	2025-07-18 17:51:43.54728-04	2ce1e6ac-d82e-49df-b59d-a3fe7ff861ce	completed	1.000000	0.700000	USD	\N	\N	\N	\N
10f4b647-9296-4119-a3c5-676564395002	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:35:24.783398-04	2025-07-18 17:51:43.54728-04	f938c92e-c1f7-4ee3-b54a-3e4d5e136c1e	completed	1.000000	0.700000	USD	\N	\N	\N	\N
144e026f-ea9e-4567-9e17-b48d8a4c229b	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:38:49.19179-04	2025-07-18 17:51:43.54728-04	67c9565b-67ff-4a3a-b2c5-05ee9207b54b	completed	1.000000	0.700000	USD	\N	\N	\N	\N
c4c771af-7bd7-4f44-b258-de1160a64dea	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:39:23.755244-04	2025-07-18 17:51:43.54728-04	ee26f59a-57bf-4790-a944-f3f34b499162	completed	1.000000	0.700000	USD	\N	\N	\N	\N
95e4ac25-fea0-475e-a2c4-cd7d34751fe1	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:41:08.313341-04	2025-07-18 17:51:43.54728-04	8bb7b0a9-96d2-487f-9b52-4599fc9fbb79	completed	1.000000	0.700000	USD	\N	\N	\N	\N
596eb749-4581-40ca-98ae-f77c9522ce6c	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:41:45.052921-04	2025-07-18 17:51:43.54728-04	cf362298-d0b9-466b-89dc-f18da80903b4	completed	1.000000	0.700000	USD	\N	\N	\N	\N
195eaf3c-4a2a-4b03-a34a-4d87ce6602c0	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 11:46:12.384907-04	2025-07-18 17:51:43.54728-04	52a822c1-1945-4a39-9d1f-18cf060c5168	completed	1.000000	0.700000	USD	\N	\N	\N	\N
8a1b5cc3-ac7d-437d-8a8e-da434bbf9928	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:15:33.201407-04	2025-07-18 17:51:43.54728-04	b3a30668-1a87-4a6c-bb2d-d80a50414b97	completed	1.000000	0.700000	USD	\N	\N	\N	\N
ef16dfa6-3780-42fe-9202-98d349d70443	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:15:54.885751-04	2025-07-18 17:51:43.54728-04	ba7c53b0-f10f-4914-b296-f939ce90fb0f	completed	1.000000	0.700000	USD	\N	\N	\N	\N
ce3c8f35-bcf0-4a89-b038-8c2150dd1a09	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:34:49.731668-04	2025-07-18 17:51:43.54728-04	2ce1e6ac-d82e-49df-b59d-a3fe7ff861ce	completed	1.000000	0.700000	USD	\N	\N	\N	\N
a2d51f85-c2e7-4cff-a18d-1f2b15535cb8	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:35:13.152889-04	2025-07-18 17:51:43.54728-04	2c40d6b9-dd7d-44c7-9e27-7d83325a7c5a	completed	1.000000	0.700000	USD	\N	\N	\N	\N
f3bca9e6-dbad-48dd-864a-ce5d2b6dc304	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:38:49.179242-04	2025-07-18 17:51:43.54728-04	67c9565b-67ff-4a3a-b2c5-05ee9207b54b	completed	1.000000	0.700000	USD	\N	\N	\N	\N
81580243-6ca7-4b0b-9202-f40a19fdf1df	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:39:12.543095-04	2025-07-18 17:51:43.54728-04	d8cee115-cac0-4a98-9bd9-c4fdb2befc1c	completed	1.000000	0.700000	USD	\N	\N	\N	\N
18bb6d86-73c4-4eb4-a5b2-ec4ed76bced4	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:41:08.302179-04	2025-07-18 17:51:43.54728-04	8bb7b0a9-96d2-487f-9b52-4599fc9fbb79	completed	1.000000	0.700000	USD	\N	\N	\N	\N
fe47c423-dd4d-4df8-aa23-475b19128b1c	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:41:34.389587-04	2025-07-18 17:51:43.54728-04	ef2fc807-1d1f-4d18-87ef-359f1393598e	completed	1.000000	0.700000	USD	\N	\N	\N	\N
9cef91af-9135-480b-8c91-ae2e75aebd87	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 11:46:12.411836-04	2025-07-18 17:51:43.54728-04	52a822c1-1945-4a39-9d1f-18cf060c5168	completed	1.000000	0.700000	USD	\N	\N	\N	\N
01a75eb2-ef2c-4fe8-964d-d19ce389892e	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:15:33.22488-04	2025-07-18 17:51:43.54728-04	b3a30668-1a87-4a6c-bb2d-d80a50414b97	completed	1.000000	0.700000	USD	\N	\N	\N	\N
703cc981-7b7d-4401-98c5-d51c235592a5	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:34:49.755816-04	2025-07-18 17:51:43.54728-04	2ce1e6ac-d82e-49df-b59d-a3fe7ff861ce	completed	1.000000	0.700000	USD	\N	\N	\N	\N
b01c6125-3694-4ad2-8edd-f1b40841a126	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:38:49.203976-04	2025-07-18 17:51:43.54728-04	67c9565b-67ff-4a3a-b2c5-05ee9207b54b	completed	1.000000	0.700000	USD	\N	\N	\N	\N
e7ec4ee2-ed05-4911-936d-74a6150f6662	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:41:08.325428-04	2025-07-18 17:51:43.54728-04	8bb7b0a9-96d2-487f-9b52-4599fc9fbb79	completed	1.000000	0.700000	USD	\N	\N	\N	\N
a0242efc-3bba-4b21-840f-2791309dcd35	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:15:41.636326-04	2025-07-18 17:51:43.54728-04	64ece526-953c-4974-8948-f74e87cadda6	completed	1.000000	0.700000	USD	\N	\N	\N	\N
f5847930-ec45-45f4-b8a3-8ec619181c50	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:35:00.053559-04	2025-07-18 17:51:43.54728-04	89839bcf-5ea7-44e4-9b6b-e440fa32e131	completed	1.000000	0.700000	USD	\N	\N	\N	\N
b50ed39d-8e3c-4fa7-8a62-b5ea4e21c7d3	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:38:59.381918-04	2025-07-18 17:51:43.54728-04	ff28a9da-ec91-42b6-9eb1-80bcb0d5c702	completed	1.000000	0.700000	USD	\N	\N	\N	\N
f5bfe4b3-6a22-4189-9904-089fed68fcb0	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:41:18.265095-04	2025-07-18 17:51:43.54728-04	19841b52-0d7e-4a14-a709-7349f33bf1a3	completed	1.000000	0.700000	USD	\N	\N	\N	\N
46f63f13-307d-4753-9d0f-3af7d6c05c90	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-11 12:17:02.112541-04	2025-07-18 17:51:43.54728-04	d6cc7341-da22-4c70-8838-a9a2d6ac9574	completed	1.000000	0.700000	USD	contextual	\N	\N	\N
cad976e4-12b5-43fc-8376-7b4e73f068bb	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-11 12:22:00.606115-04	2025-07-18 17:51:43.54728-04	183f164e-9952-49b5-afce-68b61ec1219a	completed	1.000000	0.700000	USD	contextual	\N	\N	\N
3d4a5672-016d-451b-bfe2-e3bf2ba17772	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-11 12:31:47.148248-04	2025-07-18 17:51:43.54728-04	f053db86-9c28-4409-8ae4-164abe71955e	completed	1.000000	0.700000	USD	contextual	\N	\N	\N
bb5c14e8-9464-4be1-9aed-b2d8def4a169	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:16:14.826329-04	2025-07-18 17:51:43.54728-04	a0bba5a9-1926-432a-ac5a-71d59c84eb91	completed	1.000000	0.700000	USD	\N	\N	\N	\N
22e38956-7861-4c9f-b05a-232ced9a6d3a	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:35:33.475017-04	2025-07-18 17:51:43.54728-04	6384e4a0-b350-4fec-ad5d-e059dde70a40	completed	1.000000	0.700000	USD	\N	\N	\N	\N
490dff05-39c8-45de-b432-f53e03aa9f0d	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:39:32.143897-04	2025-07-18 17:51:43.54728-04	d7039014-9648-447c-90c7-547157aeb43b	completed	1.000000	0.700000	USD	\N	\N	\N	\N
52c99653-be84-4e62-8a71-3a0d178c6ed8	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-03 21:41:53.513199-04	2025-07-18 17:51:43.54728-04	4c3fdc51-349d-484e-8b30-1426c4924a34	completed	1.000000	0.700000	USD	\N	\N	\N	\N
bebcbcab-2344-40f0-8a22-b772f23ed1ab	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-11 12:17:02.112541-04	2025-07-18 17:51:43.54728-04	d6cc7341-da22-4c70-8838-a9a2d6ac9574	completed	0.100000	0.070000	USD	contextual	\N	\N	\N
9e135475-3284-41e4-9cf3-148fcab34fb6	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-11 12:22:00.606115-04	2025-07-18 17:51:43.54728-04	183f164e-9952-49b5-afce-68b61ec1219a	completed	0.100000	0.070000	USD	contextual	\N	\N	\N
db705b5f-d9bc-46ad-bb56-60fbbd6812c5	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-11 12:31:47.148248-04	2025-07-18 17:51:43.54728-04	f053db86-9c28-4409-8ae4-164abe71955e	completed	0.100000	0.070000	USD	contextual	\N	\N	\N
e82b7ae9-59f3-4108-af00-fcafc5ccaa02	\N	\N	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	2025-07-04 11:59:45.061593-04	2025-07-18 17:51:43.54728-04	5e1db7fe-1339-4fcc-930b-2ced598ffd0f	clicked	1.000000	0.700000	USD	contextual	\N	\N	\N
\.


--
-- Data for Name: ad_queue; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ad_queue (chat_session_id, ad_id, ad_type, placement, similarity, created_at, times_served, initial_similarity, mcp_tool_call_id) FROM stdin;
\.


--
-- Data for Name: ads; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.ads (id, campaign_id, title, description, url, created_at, updated_at, deleted_at, ad_type, pricing_model, status, image_url, needs_description, estimated_epc) FROM stdin;
ebc4f957-a481-4151-b6c6-f1e5bc485dbe	406ef64f-f508-4764-a8e3-94e92abe3c0a	Test Ad 1	Test description 1	https://test1.com	2025-07-19 08:23:46.287544-04	2025-07-19 08:23:46.287544-04	\N	hyperlink	cpc	active	\N	t	10.500000
929e78ed-2695-4f3f-80a1-d4ebc1cbb3f2	273d4140-65cd-42d5-955b-8f974ecac053	Test Ad 2	Test description 2	https://test2.com	2025-07-19 08:23:46.287544-04	2025-07-19 08:23:46.287544-04	\N	banner	cpm	active	https://test2.com/image.jpg	f	5.000000
0f0754da-5799-4d53-95a2-1b5f952dbef1	406ef64f-f508-4764-a8e3-94e92abe3c0a	Test Ad 3	Test description 3	https://test3.com	2025-07-19 08:23:46.287544-04	2025-07-19 08:23:46.287544-04	\N	popup	cpc	active	\N	t	15.250000
5babb65f-dac7-4d80-97d9-4bba295bc55b	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	Wondershare Home Page	Wondershare Software is a world-class leading publisher and developer of consumer software. Wondershare products include variety of applications for Multimedia, Business, Utilities and Mobile.	https://www.jdoqocy.com/click-101484882-10890849	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	hyperlink	affiliate	active	\N	t	85.000000
307e1eac-5b7e-4fc3-b223-79f49b32ad6f	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	Wondershare PDFelement 10 - Smart PDF Solutions, Simplified by AI.	One-stop PDF solution powered by AI. Fast, affordable, and easy way to edit, convert, sign PDFs, and more - accessible across desktop, mobile, and web platforms.	https://www.jdoqocy.com/click-101484882-10942755	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	hyperlink	affiliate	active	\N	t	16.275000
3a030305-7f88-41c6-9892-e87204ad1448	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	Wondershare Video Converter Ultimate for Mac	The all-in-one video toolbox to convert, edit, download, burn, organize, capture, and play any videos on your Mac. Convert videos with 30X faster speed in lossless quality with groundbreaking APEXTRANS™ Technology	https://www.tkqlhce.com/click-101484882-11101519	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	hyperlink	affiliate	active	\N	t	5.000000
000d2b04-8e9a-4db4-bd75-3c07f032da3d	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	Wondershare PDFelement for Mac	Easily Create, Edit, Convert, Sign, OCR PDF files.	https://www.kqzyfj.com/click-101484882-11101523	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	hyperlink	affiliate	active	\N	t	31.000000
4e2286f1-9be1-4f3a-89bf-e551fa28d1b4	cb0c2f3b-913f-49a8-8560-2e5780551850	NordVPN Homepage	The most advanced VPN. And much more. One of the fastest VPNs in the world.Secure up to 10 devices with one account.Helps you avoid phishing, scams and malware. Enjoy 76 % off NordVPN + an Amazon gift card	https://www.jdoqocy.com/click-101484882-12814518	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	hyperlink	affiliate	active	\N	t	495.195000
16ae66a3-2c01-4aaf-a057-2b550ce77b66	cb0c2f3b-913f-49a8-8560-2e5780551850	Get NordVPN Up to 74% off + 3 extra month	The most advanced VPN. And much more. One of the fastest VPNs in the world.Secure up to 10 devices with one account.Helps you avoid phishing, scams and malware. Enjoy 76 % off NordVPN + an Amazon gift card	https://www.dpbolvw.net/click-101484882-15877144	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	banner	affiliate	active	https://www.ftjcfx.com/image-101484882-15877144	f	144.830000
67e793f5-c51f-4f70-934a-068ae4abd748	cb0c2f3b-913f-49a8-8560-2e5780551850	NordVPN Homepage	The most advanced VPN. And much more. One of the fastest VPNs in the world.Secure up to 10 devices with one account.Helps you avoid phishing, scams and malware. Enjoy 76 % off NordVPN + an Amazon gift card	https://www.tkqlhce.com/click-101484882-13795051	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	popup	affiliate	active	https://www.tqlkg.com/image-101484882-13795051	t	170.000000
59d35128-30a1-47fb-ad2c-5760d48e9950	a0cb719f-486d-4c6a-a981-b4a52b8f805e	Acronis Backup for Windows PCs		https://www.tkqlhce.com/click-101484882-15635150	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	banner	affiliate	active	https://www.lduhtrp.net/image-101484882-15635150	f	46.410000
7a7f63c8-27a7-4462-99f6-8a5c88d704d1	a0cb719f-486d-4c6a-a981-b4a52b8f805e	Acronis Backup for Windows PCs - landing page		https://www.tkqlhce.com/click-101484882-10594191	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	hyperlink	affiliate	active	https://www.lduhtrp.net/image-101484882-10594191	t	17.180000
61d7d76b-7c60-4ccf-bae7-9279adbf8bf6	f735a55b-288e-4c4f-b49a-deed34f92f2c	The Best ChatGPT Book for Beginners	Master Epic Prompts, Generate Stunning Dall-E Visuals, Navigate Ai Ethics, Unlock Passive Income Potential, And Enhance Your Productivity	https://www.amazon.com/dp/B0DTYXYXT1?&linkCode=ll1&tag=earnlayerai-20&linkId=ffb80193128a216ff6dc09cf829eec6e&language=en_US&ref_=as_li_ss_tl	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	hyperlink	affiliate	active	\N	t	2.812500
bdfc0914-702d-4fea-bdcc-c1a139ba8adb	f735a55b-288e-4c4f-b49a-deed34f92f2c	The Best ChatGPT Book for Beginners	Master Epic Prompts, Generate Stunning Dall-E Visuals, Navigate Ai Ethics, Unlock Passive Income Potential, And Enhance Your Productivity	https://www.amazon.com/dp/B0DTYXYXT1?&linkCode=ll1&tag=earnlayerai-20&linkId=ffb80193128a216ff6dc09cf829eec6e&language=en_US&ref_=as_li_ss_tl	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	popup	affiliate	active	https://m.media-amazon.com/images/I/71Os6xCyJZL._SL1499_.jpg	t	2.812500
dbbaf358-e075-46c6-9f3c-dc861a51dfab	e6cb7d7e-3b67-42be-8849-d16f6c135844	Ad With Description	This description should be included	https://test1.com	2025-07-19 08:32:47.867233-04	2025-07-19 08:32:47.867233-04	\N	hyperlink	cpc	active	\N	t	10.000000
49f5da7a-7218-4e2a-9ab9-6bd70846ba1b	e6cb7d7e-3b67-42be-8849-d16f6c135844	Ad Without Description	This description should NOT be included	https://test2.com	2025-07-19 08:32:47.867233-04	2025-07-19 08:32:47.867233-04	\N	hyperlink	cpc	active	\N	f	5.000000
7b8291b9-0ba7-41dc-8306-b5ec733bdcd9	8f170d7b-17ab-4245-8e99-8e010e335384	Ad With Description	This description should be included	https://test1.com	2025-07-19 08:35:21.935851-04	2025-07-19 08:35:21.935851-04	\N	hyperlink	cpc	active	\N	t	10.000000
c2ed3d4d-dbee-4564-949c-a2a27e771594	8f170d7b-17ab-4245-8e99-8e010e335384	Ad Without Description	This description should NOT be included	https://test2.com	2025-07-19 08:35:21.935851-04	2025-07-19 08:35:21.935851-04	\N	hyperlink	cpc	active	\N	f	5.000000
dcb37175-8d00-479e-b5b4-10b2f0a63420	5daa5906-1ba6-4831-9fba-320eec7b910c	Best Laptop for Developers	High-performance laptop perfect for coding and development work	https://amazon.com/dp/B08N5WRWNW?tag=EARNLAYER-12345	2025-07-23 15:19:11.441905-04	2025-07-23 15:19:11.441905-04	\N	hyperlink	affiliate	active	\N	t	0.050000
68efeac1-b343-419f-bfcc-210175135826	f46fce08-791e-46ed-94d4-6baba2bfb9ea	Test Affiliate Ad 1	Test affiliate ad 1 with URL: https://example.com/product	https://example.com/product	2025-07-23 15:32:34.532783-04	2025-07-23 15:32:34.532783-04	\N	hyperlink	affiliate	active	\N	t	0.050000
3c647e5e-97b0-4ab7-83b3-e26ea78059cb	f46fce08-791e-46ed-94d4-6baba2bfb9ea	Test Affiliate Ad 2	Test affiliate ad 2 with URL: https://amazon.com/dp/B08N5WRWNW?tag=test	https://amazon.com/dp/B08N5WRWNW?tag=test	2025-07-23 15:32:34.532783-04	2025-07-23 15:32:34.532783-04	\N	hyperlink	affiliate	active	\N	t	0.050000
39d18b8d-94ac-4920-8285-caf97544fefa	f46fce08-791e-46ed-94d4-6baba2bfb9ea	Test Affiliate Ad 3	Test affiliate ad 3 with URL: https://clickbank.com/product?ref=123	https://clickbank.com/product?ref=123	2025-07-23 15:32:34.532783-04	2025-07-23 15:32:34.532783-04	\N	hyperlink	affiliate	active	\N	t	0.050000
c1d78b05-e8fa-4bba-8cae-11a140df064a	95df4760-66b1-4d0a-9265-a9cbdc275a56	Great Tech Deal	Amazing technology product for creators	https://techcorp.com/product	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	popup	affiliate	active	\N	t	2.500000
08faa528-8b4f-4c9e-9dd7-cd203ce61d69	a5557f22-1736-4784-93e7-0a0ab5dc0adc	Best Books 2024	Top programming books every developer should read	https://bookstore.com/programming	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	banner	affiliate	active	https://bookstore.com/banner.jpg	f	1.200000
2ef027c4-d5de-406a-94b0-9b79c665427e	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	Code Editor Pro	Professional code editor with AI assistance	https://softwarecorp.com/editor	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	hyperlink	cpc	active	\N	t	3.000000
a95548d4-c7a5-4897-8bb1-bfc4cd438ee4	a2d44548-c7d3-4b13-81a0-91abe15878bd	Regular CPC Ad	This is a regular CPC ad for testing	https://testcorp.com/product	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	text	cpc	active	\N	f	1.500000
ad2cd4f6-4450-47eb-835a-f726e1c2a1f3	eae4c673-093e-40ba-8750-1866791716a0	Find, Contact & Close Your Ideal Clients	Instantly helps you find warm leads, scale email campaigns, reach primary inboxes, engage smarter and win more with AI.	https://instantly.ai/	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	\N	hyperlink	affiliate	active	\N	f	45.000000
883bd6ac-20e8-4c6e-9680-432432b05209	a9202906-7dfa-4b7c-8cad-dc47b20f6106	Drag Drop Done	Sell online and in person. Sell locally and globally. Sell direct and wholesale. Sell on desktop and mobile.	https://shopify.pxf.io/c/6374346/2944579/13624?subId1=earnlayer	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	\N	banner	affiliate	active	https://app.impact.com/display-ad/13624-2944579?v=0	f	30.000000
\.


--
-- Data for Name: advertiser_payments; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.advertiser_payments (id, advertiser_id, campaign_id, amount, currency, external_tx_id, received_at, memo, created_at, method) FROM stdin;
\.


--
-- Data for Name: advertiser_status_values; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.advertiser_status_values (value) FROM stdin;
active
paused
completed
\.


--
-- Data for Name: advertisers; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.advertisers (id, user_id, name, created_at, updated_at, deleted_at, status) FROM stdin;
ed6822db-9052-4c76-8fd2-726115bd8c8a	45f89fcb-3be9-4f24-985a-ed078d588c76	WonderShare	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	active
7b75b21e-9216-4903-ae81-33d28221f899	a2ba48f4-d3a9-42b6-a1c7-928bd3bf6d75	NordVPN	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	active
f1448859-c289-4faa-929e-595f1da1d564	a09539e0-56ff-4683-9bc2-3b44582a2b82	Acronis	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	active
17ca8f14-7ec8-4996-9012-c1c12ef37fb7	fcbddd8e-b5cb-41ee-bff0-be4eadbb9b78	Amazon Affiliate	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	\N	active
a35ffde4-c737-40c6-90f4-67b3d50fe966	7cdfbf3f-92fe-4b97-996f-dde113211fb5	TestAdv	2025-07-19 08:32:47.867233-04	2025-07-19 08:32:47.867233-04	\N	active
8a350d79-e678-40c1-b6eb-c765e1525eee	671b93af-8e85-4224-b0a1-8908e0665e13	TestAdv_5195ec8a	2025-07-19 08:35:21.935851-04	2025-07-19 08:35:21.935851-04	\N	active
20dc13ff-1a11-4d00-85c2-40fbb8626333	e8792571-696e-4377-a188-56dcf6136122	TechCorp	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	active
3fd615a3-4bcb-4c9a-825b-c74f02244bbd	043d11c7-e5db-4d4f-94ee-3d8c729432ef	BookStore	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	active
a13ebacd-97c7-492d-9202-5bd25682f7b8	f3c7c6d1-81fe-4b7e-94de-95d89406ea42	SoftwareCorp	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	active
d1609d19-277d-461c-96ae-b7365d4cd1e6	3b8b4fa4-114c-4c9a-aa66-3ae3d4e846fc	TestCorp	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N	active
afca040b-e824-40cb-94ba-2f87bf9d990d	4f543409-619d-4b7d-bfee-74723bebfef8	Instantly AI	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	\N	active
30ef66aa-1fdd-4fb3-8e58-478244d492dc	5375926e-b797-4c36-b9b6-0a28e0f2befb	Shopify	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	\N	active
09f0bf1f-cc54-43e9-a355-4c2f58e7335c	d81659b6-bb32-4d9b-95ac-7c4d52afdbff	ExistingAdvertiser	2025-07-19 08:14:44.440789-04	2025-07-19 08:14:44.440789-04	\N	active
f84e9ba6-2b4c-47a5-a887-d5cf21e8f83d	84a48840-1666-4a0e-a194-b6a3f10a9926	TestAdvertiser1	2025-07-19 08:23:46.287544-04	2025-07-19 08:23:46.287544-04	\N	active
4d3c5113-acb2-4a71-a8c0-6eaea5cc57bb	0de7f662-36c4-4c0a-9f95-cccea454d8c9	TestAdvertiser2	2025-07-19 08:23:46.287544-04	2025-07-19 08:23:46.287544-04	\N	active
\.


--
-- Data for Name: business_ad_type_preferences; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.business_ad_type_preferences (id, creator_id, ad_type, is_enabled, created_at) FROM stdin;
ecc5ab14-464f-455a-a7da-4c2a62b48018	d64a4899-20e4-4ecd-a53e-057aceed54cf	hyperlink	t	2025-08-11 16:52:38.225402-04
f4cb33c3-ac75-48f2-bab9-0f3ee8134df1	d64a4899-20e4-4ecd-a53e-057aceed54cf	popup	t	2025-08-11 16:52:38.225402-04
5dbf65be-524e-473e-bac5-3f5963a8d70e	d64a4899-20e4-4ecd-a53e-057aceed54cf	banner	t	2025-08-11 16:52:38.225402-04
2ceac0c8-a648-493b-ab22-bd6de5bc5358	d64a4899-20e4-4ecd-a53e-057aceed54cf	video	f	2025-08-11 16:52:38.225402-04
c0fe95b2-6942-4139-9543-e4112b4b7752	d64a4899-20e4-4ecd-a53e-057aceed54cf	thinking	t	2025-08-11 16:52:38.225402-04
75f2b5b6-6a28-4388-8762-94d599235f5e	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	hyperlink	t	2025-08-11 16:52:38.225402-04
2998c1ec-c31b-442b-ba8a-e985852d6589	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	popup	t	2025-08-11 16:52:38.225402-04
a5f8be74-e2ff-4e9c-ba42-0e9b6b65961f	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	banner	f	2025-08-11 16:52:38.225402-04
51ff3154-ea60-42e4-9108-612d30b29c6d	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	video	f	2025-08-11 16:52:38.225402-04
97ba2819-9146-4dd8-a621-4e0843403e09	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	thinking	f	2025-08-11 16:52:38.225402-04
68c75671-ca17-45fe-98f9-4c8a1414c592	32872c3f-b91d-4897-bd2b-b79286e6b97c	hyperlink	t	2025-08-11 16:52:38.225402-04
664a5274-ab79-4a2e-8e34-37c1194391d2	32872c3f-b91d-4897-bd2b-b79286e6b97c	popup	f	2025-08-11 16:52:38.225402-04
007ebe02-ffab-4154-bde8-18a7bbcf60e4	32872c3f-b91d-4897-bd2b-b79286e6b97c	banner	f	2025-08-11 16:52:38.225402-04
96652e23-d938-456c-accf-796574c40d20	32872c3f-b91d-4897-bd2b-b79286e6b97c	video	f	2025-08-11 16:52:38.225402-04
462bff72-54e8-4865-bb87-36cb62f90707	32872c3f-b91d-4897-bd2b-b79286e6b97c	thinking	f	2025-08-11 16:52:38.225402-04
\.


--
-- Data for Name: business_category_preferences; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.business_category_preferences (id, creator_id, category_id, preference, created_at) FROM stdin;
5756a437-c877-4583-b2f0-adebe09f42d8	d64a4899-20e4-4ecd-a53e-057aceed54cf	ec2a5375-c6ed-4c5f-b95f-5802250893a6	preferred	2025-08-11 16:52:38.225402-04
a5842175-8a82-4103-857b-5fce365cdbcc	d64a4899-20e4-4ecd-a53e-057aceed54cf	3571f043-2f22-482f-95cc-19a722652e4d	allowed	2025-08-11 16:52:38.225402-04
d8bbe095-3d7e-4606-9381-c694fd66ba71	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	ec2a5375-c6ed-4c5f-b95f-5802250893a6	preferred	2025-08-11 16:52:38.225402-04
0ee4d73a-b6d5-4e9a-9adf-b996ed925951	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	d9c158af-410d-4992-9c6e-34b4c0ac0e17	allowed	2025-08-11 16:52:38.225402-04
20cb5448-48f2-4299-84fa-fc0faa925380	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	33f86a4c-ae53-4620-9388-e514fd074fbf	blocked	2025-08-11 16:52:38.225402-04
cb91c954-5111-4542-970f-f862e4aeb220	32872c3f-b91d-4897-bd2b-b79286e6b97c	3571f043-2f22-482f-95cc-19a722652e4d	preferred	2025-08-11 16:52:38.225402-04
\.


--
-- Data for Name: business_settings; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.business_settings (id, creator_id, ad_frequency, revenue_vs_relevance, min_seconds_between_display_ads, display_ad_similarity_threshold, is_active, created_at, updated_at) FROM stdin;
0e6dd8bb-20dc-47fb-82a1-99bdc2af394c	d64a4899-20e4-4ecd-a53e-057aceed54cf	normal	0.60	45	0.30	t	2025-08-11 16:52:38.225402-04	2025-08-11 16:52:38.225402-04
622ee582-b489-4c6b-953c-542f54f683f3	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	high	0.80	20	0.20	t	2025-08-11 16:52:38.225402-04	2025-08-11 16:52:38.225402-04
1873c099-4193-4db5-a504-8cdd9074690d	32872c3f-b91d-4897-bd2b-b79286e6b97c	low	0.40	60	0.35	t	2025-08-11 16:52:38.225402-04	2025-08-11 16:52:38.225402-04
\.


--
-- Data for Name: campaign_cpc_rates; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.campaign_cpc_rates (id, campaign_id, created_at, updated_at, cpc_rate_amount, currency, placement, ad_type) FROM stdin;
a65ac35f-e632-4b53-8ad9-ab5d21f7389a	95df4760-66b1-4d0a-9265-a9cbdc275a56	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	0.000000	USD	chat_inline	text
7b16d1c4-a9c4-4489-8e80-06b7ddaf48df	a5557f22-1736-4784-93e7-0a0ab5dc0adc	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	0.000000	USD	chat_inline	text
3e27a36b-b8dd-4d57-9c79-56af78b425b0	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	0.200000	USD	chat_inline	text
8ff21b08-8eb4-4cd5-bf05-1fe18e71602c	a2d44548-c7d3-4b13-81a0-91abe15878bd	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	0.100000	USD	chat_inline	text
4a2b2a3f-7793-4563-909b-eab6c6dd43be	eae4c673-093e-40ba-8750-1866791716a0	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	0.000000	USD	chat_inline	text
618acb90-8dda-41ac-b29c-0a0a98d07aa1	a9202906-7dfa-4b7c-8cad-dc47b20f6106	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	0.000000	USD	chat_inline	text
7c176465-acc2-4185-88b0-79bf25c88548	273d4140-65cd-42d5-955b-8f974ecac053	2025-07-19 08:23:46.287544-04	2025-07-19 08:31:24.66082-04	0.000000	USD	chat_inline	text
a1e2b595-bec1-4b58-8be9-c4679da5128b	406ef64f-f508-4764-a8e3-94e92abe3c0a	2025-07-19 08:23:46.287544-04	2025-07-19 08:31:24.66082-04	15.250000	USD	chat_inline	text
af64a193-6594-4bd4-aea9-bfa9dee778f2	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	0.000000	USD	chat_inline	text
3694227c-a056-4da7-aaaf-26f20748df12	cb0c2f3b-913f-49a8-8560-2e5780551850	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	0.000000	USD	chat_inline	text
0634a9bc-8c8e-4c2e-a4f2-9310a63a776d	a0cb719f-486d-4c6a-a981-b4a52b8f805e	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	0.000000	USD	chat_inline	text
28ae9b76-e945-4303-809b-0c64e04f7c30	f735a55b-288e-4c4f-b49a-deed34f92f2c	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	0.000000	USD	chat_inline	text
\.


--
-- Data for Name: category_status_values; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.category_status_values (value) FROM stdin;
approved
blocked
inherit
\.


--
-- Data for Name: chat_messages; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.chat_messages (id, session_id, message, is_user, created_at) FROM stdin;
95699d63-08bc-46d7-9bcf-baf370b4f824	de646f6f-b8fe-4c55-a93a-77a6a0883c72	Hello, this is a test message for a new chat session.	t	2025-07-02 14:11:44.43405-04
59cbe798-6093-486c-995e-2a8b28628e4a	de646f6f-b8fe-4c55-a93a-77a6a0883c72	Hello! Welcome to the new chat session. How can I assist you today?	f	2025-07-02 14:11:48.633927-04
d0884a5c-4dd7-4d78-ab07-47e7f80e5613	de646f6f-b8fe-4c55-a93a-77a6a0883c72	This is a follow-up message in the existing chat session.	t	2025-07-02 14:11:49.485372-04
a3eeb886-4635-464f-b097-f89b30d67d5f	de646f6f-b8fe-4c55-a93a-77a6a0883c72	It seems like this is a new chat session, so I don't have access to previous messages. How can I assist you today? If you have any specific questions or topics in mind, feel free to share!	f	2025-07-02 14:11:49.494897-04
c9a1afb4-9236-4ed9-a345-ef628adee50b	43d9a3f9-2bc1-4636-b925-ba3f4004c474	Hello, this is a test message for a new chat session.	t	2025-07-02 14:13:51.295882-04
8d9200ba-d3b8-4d0b-aad6-f01bf8f6892d	43d9a3f9-2bc1-4636-b925-ba3f4004c474	Hello! Welcome to the new chat session. How can I assist you today?	f	2025-07-02 14:13:55.221758-04
f3337c24-fbf9-44e0-86d0-6f5aefd5d703	43d9a3f9-2bc1-4636-b925-ba3f4004c474	This is a follow-up message in the existing chat session.	t	2025-07-02 14:13:55.998522-04
5eec82a3-0daf-4062-85f8-087c5daea7f5	43d9a3f9-2bc1-4636-b925-ba3f4004c474	It seems like this is a new chat session, so I don't have access to previous messages. How can I assist you today? If you have any specific questions or topics in mind, feel free to share!	f	2025-07-02 14:13:56.007117-04
f69c4127-404f-41ba-8692-95a76c46f8d1	0e4f69cf-93db-4452-b897-dd39df87f996	Hello, this is a test message from an anonymous user.	t	2025-07-02 14:14:00.848001-04
a7068b6b-518b-4acd-b2ff-6b7f430df7f4	0e4f69cf-93db-4452-b897-dd39df87f996	Hello! If you have any questions or need assistance, feel free to ask. I'm here to help!	f	2025-07-02 14:14:04.76334-04
ad62244e-54a2-4c69-afa0-33adee86dd43	44f10ab4-6f11-4099-b5c2-9d654690cb6e	I want to grow my newsletter and increase subscriber engagement	t	2025-07-03 11:39:46.495744-04
a8927483-3632-40a8-ae9c-1c738c337164	44f10ab4-6f11-4099-b5c2-9d654690cb6e	Here are some strategies to help you grow your newsletter and increase subscriber engagement:\n\n1. **Content Quality**: Ensure that your newsletter content is valuable, informative, and engaging. Tailor your content to meet the interests and needs of your audience.\n\n2. **Segmentation**: Segment your audience based on their interests or behaviors. This allows you to send targeted content that resonates more with each group.\n\n3. **Personalization**: Use personalization techniques, such as addressing subscribers by their names and recommending content based on their previous interactions.\n\n4. **Call to Action (CTA)**: Include clear and compelling CTAs in your newsletters to encourage readers to take specific actions, such as sharing the newsletter or visiting your website.\n\n5. **Incentives**: Offer incentives for subscribing, such as exclusive content, discounts, or freebies. This can attract new subscribers and keep current ones engaged.\n\n6. **Feedback and Surveys**: Regularly ask for feedback from your subscribers to understand their preferences and improve your content accordingly.\n\n7. **Social Media Promotion**: Promote your newsletter on social media platforms to reach a wider audience. Share snippets of your newsletter content to entice followers to subscribe.\n\n8. **Consistent Schedule**: Maintain a consistent sending schedule so subscribers know when to expect your newsletter. This builds anticipation and engagement.\n\n9. **A/B Testing**: Experiment with different subject lines, content formats, and sending times to see what resonates best with your audience.\n\n10. **Analytics**: Use analytics tools to track open rates, click-through rates, and subscriber growth. This data can help you refine your strategies over time.\n\nBy implementing these strategies, you can effectively grow your newsletter and enhance subscriber engagement.	f	2025-07-03 11:40:01.023795-04
066d4578-5c0e-4122-9df1-5a2361acfabd	31222503-8def-4631-b6c1-57dfaed18c2b	I want to grow my newsletter and increase subscriber engagement	t	2025-07-03 11:43:37.72293-04
fb7c1537-0971-4052-b0bd-27d78ab1f238	31222503-8def-4631-b6c1-57dfaed18c2b	Here are some strategies to help you grow your newsletter and increase subscriber engagement:\n\n1. **Content Quality**: Ensure that your newsletter content is valuable, informative, and engaging. Focus on topics that resonate with your audience.\n\n2. **Segmentation**: Segment your audience based on their interests and preferences. This allows you to tailor content specifically for different groups, increasing relevance and engagement.\n\n3. **Personalization**: Use personalized greetings and content recommendations based on subscriber behavior. This can make your readers feel more connected to your newsletter.\n\n4. **Call to Action (CTA)**: Include clear and compelling CTAs in your newsletters. Encourage readers to take specific actions, such as sharing the newsletter, visiting your website, or engaging on social media.\n\n5. **Incentives**: Offer incentives for subscribing, such as exclusive content, discounts, or freebies. This can attract new subscribers and keep current ones engaged.\n\n6. **Feedback Loop**: Encourage feedback from your subscribers. Use surveys or polls to understand their preferences and improve your content accordingly.\n\n7. **Consistent Schedule**: Maintain a consistent sending schedule. Whether it's weekly, bi-weekly, or monthly, consistency helps build anticipation among your subscribers.\n\n8. **Social Media Promotion**: Promote your newsletter on social media platforms. Share snippets of your content to entice followers to subscribe.\n\n9. **Collaborations**: Partner with other creators or businesses to cross-promote each other's newsletters. This can help you reach a wider audience.\n\n10. **Analytics**: Use analytics to track open rates, click-through rates, and subscriber growth. This data can help you refine your strategies over time.\n\nBy implementing these strategies, you can effectively grow your newsletter and enhance subscriber engagement.	f	2025-07-03 11:43:49.649005-04
637916c0-096a-4653-925c-b766cb2a2d4c	52a822c1-1945-4a39-9d1f-18cf060c5168	I want to grow my newsletter and increase subscriber engagement	t	2025-07-03 11:45:53.919216-04
0026e56d-e02d-47c0-8edb-af71075e4f74	52a822c1-1945-4a39-9d1f-18cf060c5168	Here are some strategies to help you grow your newsletter and increase subscriber engagement:\n\n1. **Content Quality**: Ensure that your newsletter content is valuable, informative, and engaging. Tailor your content to meet the interests and needs of your audience.\n\n2. **Segmentation**: Segment your audience based on their interests or behaviors. This allows you to send targeted content that resonates more with specific groups.\n\n3. **Personalization**: Use personalization techniques, such as addressing subscribers by their names and recommending content based on their previous interactions.\n\n4. **Call to Action (CTA)**: Include clear and compelling CTAs in your newsletters to encourage readers to take specific actions, such as sharing the newsletter or visiting your website.\n\n5. **Incentives**: Offer incentives for subscribing, such as exclusive content, discounts, or freebies. This can attract new subscribers and keep current ones engaged.\n\n6. **Feedback and Surveys**: Regularly ask for feedback from your subscribers to understand their preferences and improve your content accordingly.\n\n7. **Social Media Promotion**: Promote your newsletter on social media platforms to reach a wider audience. Share snippets of your newsletter content to entice followers to subscribe.\n\n8. **Consistent Schedule**: Maintain a consistent sending schedule so subscribers know when to expect your newsletter. This builds anticipation and engagement.\n\n9. **A/B Testing**: Experiment with different subject lines, content formats, and sending times to see what resonates best with your audience.\n\n10. **Analytics**: Use analytics tools to track open rates, click-through rates, and subscriber growth. This data can help you refine your strategies over time.\n\nImplementing these strategies can help you effectively grow your newsletter and enhance subscriber engagement.	f	2025-07-03 11:46:11.335771-04
56d3b62c-3ce3-44d9-a4e7-c98cbc9a8bae	b3a30668-1a87-4a6c-bb2d-d80a50414b97	I want to grow my newsletter and increase subscriber engagement	t	2025-07-03 21:15:17.270317-04
4f1ece43-7921-4ed0-84df-d7aa1eec230f	b3a30668-1a87-4a6c-bb2d-d80a50414b97	Here are some insights on growing your newsletter and increasing subscriber engagement:\n\n1. **Content Quality**: Focus on providing high-quality, valuable content that resonates with your audience. This could include tips, insights, or exclusive information that they can't find elsewhere.\n\n2. **Consistent Schedule**: Send your newsletters on a regular schedule (weekly, bi-weekly, etc.) to keep your audience engaged and expecting your content.\n\n3. **Personalization**: Use subscriber data to personalize your newsletters. Tailoring content to individual preferences can significantly increase engagement.\n\n4. **Interactive Elements**: Incorporate polls, surveys, or questions to encourage interaction. This not only engages subscribers but also provides you with valuable feedback.\n\n5. **Clear Call-to-Action**: Make sure each newsletter has a clear call-to-action (CTA), whether it's to read a blog post, follow you on social media, or share the newsletter with friends.\n\n6. **Incentives for Subscribing**: Offer incentives for new subscribers, such as exclusive content, discounts, or freebies.\n\n7. **Social Media Promotion**: Promote your newsletter on social media platforms to reach a wider audience. Share snippets or highlights from your newsletter to entice followers to subscribe.\n\n8. **Analyze and Adapt**: Regularly analyze your newsletter performance metrics (open rates, click rates, etc.) to understand what works and what doesn’t, and adapt your strategy accordingly.\n\nBy implementing these strategies, you can effectively grow your newsletter and enhance subscriber engagement.	f	2025-07-03 21:15:32.115609-04
2891cee7-0b43-469e-acf0-edd480c9e154	64ece526-953c-4974-8948-f74e87cadda6	I need marketing tools for my business	t	2025-07-03 21:15:33.262391-04
9c364f69-127c-444d-88a9-260de5862e91	64ece526-953c-4974-8948-f74e87cadda6	Here are some marketing tools that can benefit your business:\n\n1. **Marketing Tools for Business**: These tools help streamline your marketing efforts, improve customer engagement, and analyze performance.\n\n2. **Best Marketing Tools**: A selection of top-rated tools that can enhance your marketing strategies, including social media management, email marketing, and analytics.\n\n3. **Digital Marketing Tools**: Tools specifically designed for online marketing, including SEO tools, content management systems, and advertising platforms.\n\nIf you need more specific recommendations or details about any particular tool, feel free to ask!	f	2025-07-03 21:15:40.618548-04
2fdc0e84-7b32-4e5c-9256-afce2464912a	ba7c53b0-f10f-4914-b296-f939ce90fb0f	Help me with social media marketing strategies	t	2025-07-03 21:15:41.681438-04
9289dfbf-9d7a-4c5f-b416-308fc586a610	ba7c53b0-f10f-4914-b296-f939ce90fb0f	Here are some effective social media marketing strategies you can consider:\n\n1. **Define Your Goals**: Clearly outline what you want to achieve with your social media marketing. This could include increasing brand awareness, generating leads, or driving website traffic.\n\n2. **Know Your Audience**: Understand who your target audience is, including their demographics, interests, and behaviors. This will help you tailor your content to meet their needs.\n\n3. **Choose the Right Platforms**: Not all social media platforms are suitable for every business. Choose the platforms where your target audience is most active.\n\n4. **Create Engaging Content**: Develop high-quality, engaging content that resonates with your audience. This can include images, videos, infographics, and blog posts.\n\n5. **Utilize Paid Advertising**: Consider using paid social media advertising to reach a larger audience. Platforms like Facebook, Instagram, and LinkedIn offer targeted advertising options.\n\n6. **Engage with Your Audience**: Respond to comments, messages, and mentions. Engaging with your audience helps build relationships and fosters loyalty.\n\n7. **Analyze and Adjust**: Regularly analyze your social media performance using analytics tools. Adjust your strategies based on what works and what doesn’t.\n\n8. **Leverage Influencer Marketing**: Collaborate with influencers in your industry to reach a wider audience and build credibility.\n\n9. **Run Contests and Giveaways**: Encourage engagement and attract new followers by running contests or giveaways.\n\n10. **Stay Updated on Trends**: Keep an eye on social media trends and adapt your strategies accordingly to stay relevant.\n\nThese strategies can help you create a robust social media marketing plan that drives results.	f	2025-07-03 21:15:53.876817-04
d966196a-80c1-49a3-ba58-245fa3d0c357	ae7e9937-6716-484b-ad27-6372be336e62	I want to improve my email marketing campaigns	t	2025-07-03 21:15:54.912946-04
505180f2-fffe-4319-a5a6-e6bbb1ef272b	ae7e9937-6716-484b-ad27-6372be336e62	Improving your email marketing campaigns can significantly enhance engagement and conversion rates. Here are some strategies you can consider:\n\n1. **Segment Your Audience**: Divide your email list into segments based on demographics, behavior, or purchase history. This allows you to send more targeted and relevant content.\n\n2. **Personalize Your Emails**: Use the recipient's name and tailor content based on their preferences or past interactions. Personalized emails can lead to higher open and click-through rates.\n\n3. **Optimize Subject Lines**: Craft compelling subject lines that grab attention and encourage opens. A/B test different subject lines to see what resonates best with your audience.\n\n4. **Focus on Content Quality**: Provide valuable content that addresses your audience's needs and interests. This could include tips, guides, or exclusive offers.\n\n5. **Use Clear Calls to Action (CTAs)**: Make sure your emails have clear and compelling CTAs that guide recipients on what to do next, whether it's visiting your website, making a purchase, or signing up for an event.\n\n6. **Test and Analyze**: Regularly test different elements of your emails (like design, content, and timing) and analyze the results. Use metrics like open rates, click-through rates, and conversion rates to gauge success.\n\n7. **Mobile Optimization**: Ensure your emails are mobile-friendly, as a significant portion of users check their emails on mobile devices.\n\n8. **Automate Where Possible**: Use automation tools to send timely emails based on user behavior, such as welcome emails, cart abandonment reminders, or re-engagement campaigns.\n\n9. **Maintain a Consistent Schedule**: Establish a regular sending schedule to keep your audience engaged without overwhelming them.\n\n10. **Gather Feedback**: Encourage recipients to provide feedback on your emails. This can help you understand what works and what doesn’t.\n\nIf you need specific tools or resources to implement these strategies, let me know!	f	2025-07-03 21:16:04.302642-04
597fc8c4-f0f7-4242-9995-3a59adf36058	a0bba5a9-1926-432a-ac5a-71d59c84eb91	I need content creation tools and analytics	t	2025-07-03 21:16:05.807202-04
dd7d2f82-90a4-4786-aff5-596053e85a0f	a0bba5a9-1926-432a-ac5a-71d59c84eb91	Here are some insights related to content creation tools and analytics:\n\n### Content Creation Tools\n- Various tools are available for creating engaging content, including graphic design software, video editing applications, and writing assistants.\n\n### Analytics Tools\n- Analytics tools help track performance metrics, user engagement, and content effectiveness, providing valuable insights for optimizing strategies.\n\nIf you need specific recommendations or further details on any particular tools, feel free to ask!	f	2025-07-03 21:16:13.812193-04
daa9d27e-19e4-4d1c-85b5-b03665231b90	2ce1e6ac-d82e-49df-b59d-a3fe7ff861ce	I want to grow my newsletter and increase subscriber engagement	t	2025-07-03 21:34:37.623831-04
01876b4d-7258-4eb2-a8ac-4393f56ff4ab	8bb7b0a9-96d2-487f-9b52-4599fc9fbb79	Here are some insights on growing your newsletter and increasing subscriber engagement:\n\n### Grow Your Newsletter\n1. **Content Quality**: Focus on providing valuable and relevant content that resonates with your audience.\n2. **Promote on Social Media**: Share snippets or highlights from your newsletter on social media platforms to attract new subscribers.\n3. **Collaborate with Influencers**: Partner with influencers in your niche to reach a broader audience.\n4. **Offer Incentives**: Consider offering exclusive content, discounts, or freebies to encourage sign-ups.\n\n### Increase Subscriber Engagement\n1. **Personalization**: Tailor your content to meet the interests and preferences of your subscribers.\n2. **Interactive Content**: Include polls, surveys, or quizzes to engage your audience actively.\n3. **Regular Communication**: Maintain a consistent schedule for sending out newsletters to keep your audience engaged.\n4. **Feedback Loop**: Encourage feedback and suggestions from your subscribers to make them feel valued and involved.\n\nImplementing these strategies can help you grow your newsletter and foster a more engaged subscriber base.	f	2025-07-03 21:41:07.259061-04
66be4461-e407-419d-8463-52a3e46a75c7	2ce1e6ac-d82e-49df-b59d-a3fe7ff861ce	Here are some insights on growing your newsletter and increasing subscriber engagement:\n\n1. **Content Quality**: Focus on providing high-quality, valuable content that resonates with your audience. This can include tips, insights, or exclusive information that they can't find elsewhere.\n\n2. **Consistent Schedule**: Send your newsletters on a regular schedule (weekly, bi-weekly, etc.) to keep your audience engaged and expecting your content.\n\n3. **Personalization**: Use subscriber data to personalize your newsletters. Tailoring content to individual preferences can significantly increase engagement.\n\n4. **Interactive Elements**: Incorporate polls, surveys, or questions to encourage interaction. This not only engages your audience but also provides you with valuable feedback.\n\n5. **Clear Call-to-Action**: Make sure each newsletter has a clear call-to-action (CTA), whether it's to read a blog post, follow you on social media, or share the newsletter with friends.\n\n6. **Incentives for Subscribing**: Offer incentives for new subscribers, such as exclusive content, discounts, or freebies.\n\n7. **Social Media Promotion**: Promote your newsletter on social media platforms to reach a wider audience. Share snippets or highlights from your newsletter to entice followers to subscribe.\n\n8. **Analyze and Adapt**: Regularly analyze your newsletter performance metrics (open rates, click-through rates) to understand what works and what doesn’t, and adapt your strategy accordingly.\n\nBy implementing these strategies, you can effectively grow your newsletter and enhance subscriber engagement.	f	2025-07-03 21:34:48.678068-04
23f819b7-964b-4c02-9cbf-4efc720fd764	89839bcf-5ea7-44e4-9b6b-e440fa32e131	I need marketing tools for my business	t	2025-07-03 21:34:49.794033-04
fb20e6a9-d4c5-470e-be00-4db321a66eee	89839bcf-5ea7-44e4-9b6b-e440fa32e131	It seems that there are currently no specific ads or content related to marketing tools for your business. However, I can suggest some popular marketing tools that are widely used:\n\n1. **HubSpot**: A comprehensive inbound marketing, sales, and service software that helps businesses grow.\n\n2. **Mailchimp**: An email marketing service that allows you to manage and communicate with your clients, customers, and other interested parties.\n\n3. **Hootsuite**: A social media management platform that allows you to schedule posts, track social media engagement, and analyze performance.\n\n4. **Canva**: A graphic design tool that makes it easy to create marketing materials, social media graphics, and more.\n\n5. **Google Analytics**: A web analytics service that tracks and reports website traffic, helping you understand your audience better.\n\n6. **SEMrush**: A tool for SEO, PPC, and content marketing that provides insights into your competitors and helps improve your online visibility.\n\n7. **Buffer**: A social media management tool that helps you schedule posts, analyze performance, and manage all your social media accounts in one place.\n\nIf you have specific needs or areas of marketing you're interested in, let me know, and I can provide more tailored recommendations!	f	2025-07-03 21:34:59.030132-04
17fff9ac-9678-44c7-8a53-ba320831e201	2c40d6b9-dd7d-44c7-9e27-7d83325a7c5a	Help me with social media marketing strategies	t	2025-07-03 21:35:00.095801-04
560358e5-ea3d-4b07-aad6-06340876365e	2c40d6b9-dd7d-44c7-9e27-7d83325a7c5a	Here are some effective social media marketing strategies you can consider:\n\n1. **Define Your Goals**: Clearly outline what you want to achieve with your social media marketing. This could include increasing brand awareness, generating leads, or driving website traffic.\n\n2. **Know Your Audience**: Understand who your target audience is, including their demographics, interests, and behaviors. This will help you tailor your content to meet their needs.\n\n3. **Choose the Right Platforms**: Not all social media platforms are suitable for every business. Select the platforms where your target audience is most active.\n\n4. **Create Engaging Content**: Develop high-quality, engaging content that resonates with your audience. This can include images, videos, infographics, and blog posts.\n\n5. **Utilize Paid Advertising**: Consider using paid social media advertising to reach a larger audience. Platforms like Facebook, Instagram, and LinkedIn offer targeted advertising options.\n\n6. **Engage with Your Audience**: Respond to comments, messages, and mentions. Engaging with your audience helps build relationships and fosters loyalty.\n\n7. **Analyze and Adjust**: Regularly analyze your social media performance using analytics tools. Adjust your strategies based on what works and what doesn’t.\n\n8. **Leverage Influencer Marketing**: Collaborate with influencers in your industry to reach a broader audience and gain credibility.\n\n9. **Run Contests and Giveaways**: Encourage engagement and attract new followers by running contests or giveaways.\n\n10. **Stay Updated on Trends**: Keep an eye on social media trends and adapt your strategies accordingly to stay relevant.\n\nThese strategies can help you create a robust social media marketing plan that drives results.	f	2025-07-03 21:35:12.132903-04
173243e5-140c-49ce-aa21-3230d1560871	f938c92e-c1f7-4ee3-b54a-3e4d5e136c1e	I want to improve my email marketing campaigns	t	2025-07-03 21:35:13.180264-04
e5c75031-4eaf-4cb0-8fdb-14228400087b	f938c92e-c1f7-4ee3-b54a-3e4d5e136c1e	Improving your email marketing campaigns can significantly enhance engagement and conversion rates. Here are some strategies you can consider:\n\n1. **Segment Your Audience**: Divide your email list into smaller segments based on demographics, behavior, or purchase history. This allows you to send more targeted and relevant content.\n\n2. **Personalize Your Emails**: Use the recipient's name and tailor content based on their preferences or past interactions. Personalized emails tend to have higher open and click-through rates.\n\n3. **Optimize Subject Lines**: Craft compelling subject lines that grab attention and encourage opens. A/B testing different subject lines can help you find what resonates best with your audience.\n\n4. **Focus on Content Quality**: Provide valuable content that addresses your audience's needs and interests. This could include tips, insights, or exclusive offers.\n\n5. **Use Clear Calls to Action (CTAs)**: Make sure your emails have clear and compelling CTAs that guide recipients on what to do next, whether it's visiting your website, signing up for a webinar, or making a purchase.\n\n6. **Test and Analyze**: Regularly test different elements of your emails (like layout, images, and CTAs) and analyze the results. Use metrics such as open rates, click-through rates, and conversion rates to gauge success.\n\n7. **Mobile Optimization**: Ensure your emails are mobile-friendly, as a significant portion of users check their emails on mobile devices.\n\n8. **Automate Where Possible**: Use automation tools to send timely emails based on user behavior, such as welcome emails, cart abandonment reminders, or re-engagement campaigns.\n\n9. **Maintain a Consistent Schedule**: Establish a regular sending schedule to keep your audience engaged without overwhelming them.\n\n10. **Gather Feedback**: Encourage recipients to provide feedback on your emails. This can help you understand what works and what doesn’t.\n\nIf you need specific tools or resources to implement these strategies, let me know!	f	2025-07-03 21:35:23.771495-04
9671db55-ef72-42d8-8791-f9dc3514f416	6384e4a0-b350-4fec-ad5d-e059dde70a40	I need content creation tools and analytics	t	2025-07-03 21:35:25.323533-04
2470f499-3dec-4024-85ce-62f81baa37e8	6384e4a0-b350-4fec-ad5d-e059dde70a40	Here are some insights related to content creation tools and analytics:\n\n### Content Creation Tools\n- Various tools are available for creating engaging content, including graphic design software, video editing applications, and writing assistants.\n\n### Analytics Tools\n- Analytics tools help track performance metrics, user engagement, and content effectiveness, providing valuable insights for optimizing strategies.\n\nIf you need specific recommendations or further details on any particular tools, feel free to ask!	f	2025-07-03 21:35:32.464814-04
d2b84500-0782-4fba-b4cf-d7ee4df14f43	67c9565b-67ff-4a3a-b2c5-05ee9207b54b	I want to grow my newsletter and increase subscriber engagement	t	2025-07-03 21:38:36.207141-04
cf96cd5f-561b-4a52-8eae-0fd48e72e41d	19841b52-0d7e-4a14-a709-7349f33bf1a3	I need marketing tools for my business	t	2025-07-03 21:41:08.363733-04
0b6fcba8-86f5-488e-9de5-7e8747a7ace9	67c9565b-67ff-4a3a-b2c5-05ee9207b54b	Here are some insights on growing your newsletter and increasing subscriber engagement:\n\n1. **Content Quality**: Focus on providing high-quality, valuable content that resonates with your audience. This can include tips, insights, or exclusive information that they can't find elsewhere.\n\n2. **Segmentation**: Segment your audience based on their interests and preferences. This allows you to tailor your content to different groups, making it more relevant and engaging.\n\n3. **Interactive Elements**: Incorporate interactive elements such as polls, surveys, or quizzes to engage your subscribers and encourage them to participate.\n\n4. **Personalization**: Use personalization techniques to address subscribers by their names and recommend content based on their previous interactions.\n\n5. **Consistent Schedule**: Maintain a consistent publishing schedule so that subscribers know when to expect your newsletter. This builds anticipation and loyalty.\n\n6. **Call to Action**: Include clear calls to action in your newsletters, encouraging subscribers to share your content, follow you on social media, or engage in discussions.\n\n7. **Feedback Loop**: Encourage feedback from your subscribers to understand their needs and preferences better. This can help you refine your content strategy.\n\n8. **Promotions and Incentives**: Consider offering promotions, discounts, or exclusive content to incentivize subscribers to engage more with your newsletter.\n\nBy implementing these strategies, you can effectively grow your newsletter and enhance subscriber engagement.	f	2025-07-03 21:38:48.135411-04
3269b96c-090d-4d3b-a8d4-8ace0f28b3be	ff28a9da-ec91-42b6-9eb1-80bcb0d5c702	I need marketing tools for my business	t	2025-07-03 21:38:49.239491-04
d1a0e789-7883-41da-b434-3fbac5914762	ff28a9da-ec91-42b6-9eb1-80bcb0d5c702	Here are some marketing tools that can benefit your business:\n\n1. **Marketing Tools for Business**: Various tools are available to enhance your marketing strategies, including analytics platforms, social media management tools, and email marketing services.\n\n2. **Best Marketing Tools**: Some of the top-rated marketing tools include:\n   - HubSpot: For inbound marketing and CRM.\n   - Mailchimp: For email marketing campaigns.\n   - Hootsuite: For social media management.\n   - Google Analytics: For tracking website performance.\n\n3. **Digital Marketing Tools**: These tools help in executing digital marketing strategies effectively:\n   - SEMrush: For SEO and content marketing.\n   - Canva: For graphic design and content creation.\n   - Buffer: For scheduling social media posts.\n\nIf you need more specific recommendations or details about any of these tools, feel free to ask!	f	2025-07-03 21:38:58.358824-04
7e842eb1-459b-468c-bda3-6a1530d5cf21	d8cee115-cac0-4a98-9bd9-c4fdb2befc1c	Help me with social media marketing strategies	t	2025-07-03 21:38:59.42723-04
2b667807-5623-45bd-900b-d546be3b3d9f	d8cee115-cac0-4a98-9bd9-c4fdb2befc1c	Here are some effective social media marketing strategies and tips:\n\n1. **Define Your Goals**: Clearly outline what you want to achieve with your social media marketing. This could include increasing brand awareness, generating leads, or driving website traffic.\n\n2. **Know Your Audience**: Understand who your target audience is, including their demographics, interests, and behaviors. This will help you tailor your content to meet their needs.\n\n3. **Choose the Right Platforms**: Not all social media platforms are suitable for every business. Select the platforms that align with your audience and business goals (e.g., Instagram for visual content, LinkedIn for B2B).\n\n4. **Create Engaging Content**: Develop high-quality, engaging content that resonates with your audience. This can include images, videos, infographics, and blog posts.\n\n5. **Utilize Paid Advertising**: Consider using paid social media advertising to reach a larger audience. Platforms like Facebook and Instagram offer targeted advertising options.\n\n6. **Engage with Your Audience**: Respond to comments, messages, and mentions. Engaging with your audience builds community and loyalty.\n\n7. **Analyze and Adjust**: Regularly review your social media analytics to understand what’s working and what’s not. Use this data to adjust your strategy accordingly.\n\n8. **Stay Consistent**: Maintain a consistent posting schedule to keep your audience engaged and informed.\n\n9. **Leverage Influencer Marketing**: Collaborate with influencers in your industry to reach a broader audience and build credibility.\n\n10. **Monitor Trends**: Stay updated on social media trends and adapt your strategy to incorporate new features and popular content types.\n\nThese strategies can help you create a robust social media marketing plan that drives results.	f	2025-07-03 21:39:11.521116-04
c86e5033-a03e-40a5-befe-211c80410594	ee26f59a-57bf-4790-a944-f3f34b499162	I want to improve my email marketing campaigns	t	2025-07-03 21:39:12.567199-04
089c7934-6721-4812-a3f7-b8d433c0c8d9	ee26f59a-57bf-4790-a944-f3f34b499162	Improving your email marketing campaigns can significantly enhance engagement and conversion rates. Here are some strategies you can consider:\n\n1. **Segment Your Audience**: Divide your email list into smaller segments based on demographics, behavior, or purchase history. This allows you to send more targeted and relevant content.\n\n2. **Personalize Your Emails**: Use the recipient's name and tailor content based on their preferences or past interactions. Personalized emails tend to have higher open and click-through rates.\n\n3. **Optimize Subject Lines**: Craft compelling subject lines that grab attention and encourage opens. A/B test different subject lines to see what resonates best with your audience.\n\n4. **Focus on Content Quality**: Provide valuable content that addresses your audience's needs and interests. This could include tips, guides, or exclusive offers.\n\n5. **Use Clear Calls to Action (CTAs)**: Make sure your emails have clear and compelling CTAs that guide recipients on what to do next, whether it's visiting your website, making a purchase, or signing up for an event.\n\n6. **Test and Analyze**: Regularly test different elements of your emails (like layout, images, and CTAs) and analyze the results. Use metrics like open rates, click-through rates, and conversion rates to gauge success.\n\n7. **Mobile Optimization**: Ensure your emails are mobile-friendly, as a significant portion of users check their emails on mobile devices.\n\n8. **Timing and Frequency**: Experiment with different sending times and frequencies to find the optimal schedule for your audience.\n\n9. **Automate Where Possible**: Use automation tools to send welcome emails, follow-ups, and re-engagement campaigns based on user behavior.\n\n10. **Gather Feedback**: Encourage recipients to provide feedback on your emails. This can help you understand what they like and what can be improved.\n\nIf you need specific tools or resources to implement these strategies, let me know!	f	2025-07-03 21:39:22.744178-04
40881b42-f9c7-44bd-8e10-da110a4fd88f	d7039014-9648-447c-90c7-547157aeb43b	I need content creation tools and analytics	t	2025-07-03 21:39:24.334836-04
ab4e6ca7-3fba-4084-9822-bfec4478f44c	d7039014-9648-447c-90c7-547157aeb43b	Here are some insights related to content creation tools and analytics:\n\n### Content Creation Tools\n- Various tools are available for creating engaging content, including graphic design software, video editing applications, and writing assistants.\n\n### Analytics Tools\n- Analytics tools help track performance metrics, user engagement, and content effectiveness, providing valuable insights for optimizing strategies.\n\nIf you need specific recommendations or further details on any particular tools, feel free to ask!	f	2025-07-03 21:39:31.121664-04
91f50d2e-731a-4569-9ff2-137536c85b6c	8bb7b0a9-96d2-487f-9b52-4599fc9fbb79	I want to grow my newsletter and increase subscriber engagement	t	2025-07-03 21:40:57.646341-04
56c07127-8e96-49e7-8cc7-e4a610454eea	19841b52-0d7e-4a14-a709-7349f33bf1a3	Here are some marketing tools that can benefit your business:\n\n1. **Marketing Tools for Business**: These tools help streamline your marketing efforts, improve customer engagement, and analyze performance.\n\n2. **Best Marketing Tools**: A selection of top-rated tools that can enhance your marketing strategies, including social media management, email marketing, and analytics.\n\n3. **Digital Marketing Tools**: Tools specifically designed for online marketing, including SEO tools, content management systems, and advertising platforms.\n\nIf you need more specific recommendations or details about any particular tool, feel free to ask!	f	2025-07-03 21:41:17.247137-04
e598b2f8-2c9e-4ce0-a9a7-47ccd0c47b3e	ef2fc807-1d1f-4d18-87ef-359f1393598e	Help me with social media marketing strategies	t	2025-07-03 21:41:18.316183-04
7789d3fd-7baf-4e7b-9908-1c369e1a7ee2	ef2fc807-1d1f-4d18-87ef-359f1393598e	Here are some effective social media marketing strategies you can consider:\n\n1. **Define Your Goals**: Clearly outline what you want to achieve with your social media marketing. This could include increasing brand awareness, generating leads, or boosting sales.\n\n2. **Know Your Audience**: Understand who your target audience is, their interests, and where they spend their time online. This will help you tailor your content to meet their needs.\n\n3. **Choose the Right Platforms**: Not all social media platforms are suitable for every business. Focus on the platforms where your audience is most active.\n\n4. **Create Engaging Content**: Use a mix of content types, such as images, videos, infographics, and articles, to keep your audience engaged. Make sure your content is valuable and relevant.\n\n5. **Utilize Paid Advertising**: Consider using paid ads to reach a larger audience. Platforms like Facebook and Instagram offer targeted advertising options that can help you reach specific demographics.\n\n6. **Engage with Your Audience**: Respond to comments, messages, and mentions. Engaging with your audience builds community and loyalty.\n\n7. **Analyze and Adjust**: Use analytics tools to track the performance of your social media efforts. Analyze what works and what doesn’t, and adjust your strategy accordingly.\n\n8. **Stay Consistent**: Consistency in posting and branding helps build recognition and trust with your audience.\n\n9. **Leverage Influencer Marketing**: Collaborate with influencers in your industry to reach a wider audience and gain credibility.\n\n10. **Monitor Trends**: Stay updated on social media trends and adapt your strategy to incorporate new features and changes in user behavior.\n\nThese strategies can help you create a robust social media marketing plan that drives results.	f	2025-07-03 21:41:33.367353-04
972fdca2-c60b-475f-abe4-5e95824fac7d	cf362298-d0b9-466b-89dc-f18da80903b4	I want to improve my email marketing campaigns	t	2025-07-03 21:41:34.423432-04
cb715c50-cdb1-414e-b3ba-92e5c7dadd1a	cf362298-d0b9-466b-89dc-f18da80903b4	Improving your email marketing campaigns can significantly enhance engagement and conversion rates. Here are some strategies you can consider:\n\n1. **Segment Your Audience**: Divide your email list into segments based on demographics, behavior, or purchase history. This allows you to send more targeted and relevant content.\n\n2. **Personalize Your Emails**: Use the recipient's name and tailor content based on their preferences or past interactions. Personalized emails can lead to higher open and click-through rates.\n\n3. **Optimize Subject Lines**: Craft compelling subject lines that grab attention and encourage opens. A/B test different subject lines to see what resonates best with your audience.\n\n4. **Focus on Content Quality**: Provide valuable content that addresses your audience's needs and interests. This could include tips, guides, or exclusive offers.\n\n5. **Use Clear Calls to Action (CTAs)**: Make sure your emails have clear and compelling CTAs that guide recipients on what to do next, whether it's visiting your website, making a purchase, or signing up for an event.\n\n6. **Test and Analyze**: Regularly test different elements of your emails (like layout, images, and CTAs) and analyze the results. Use metrics like open rates, click-through rates, and conversion rates to gauge success.\n\n7. **Mobile Optimization**: Ensure your emails are mobile-friendly, as a significant portion of users check their emails on mobile devices.\n\n8. **Automate Where Possible**: Use automation tools to send timely emails based on user behavior, such as welcome emails, cart abandonment reminders, or re-engagement campaigns.\n\n9. **Maintain a Consistent Schedule**: Establish a regular sending schedule to keep your audience engaged without overwhelming them.\n\n10. **Gather Feedback**: Encourage recipients to provide feedback on your emails. This can help you understand what works and what doesn’t.\n\nIf you need specific tools or resources to implement these strategies, let me know!	f	2025-07-03 21:41:44.027564-04
7e2d922a-253d-486e-824e-1fbcef1da517	4c3fdc51-349d-484e-8b30-1426c4924a34	I need content creation tools and analytics	t	2025-07-03 21:41:45.60175-04
c15e8bc2-d2d8-42c4-9cf0-278b9c795722	4c3fdc51-349d-484e-8b30-1426c4924a34	Here are some insights related to content creation tools and analytics:\n\n### Content Creation Tools\n- Various tools are available for creating engaging content, including graphic design software, video editing applications, and writing assistants.\n\n### Analytics Tools\n- Analytics tools help track performance metrics, user engagement, and content effectiveness, providing valuable insights for optimizing strategies.\n\nIf you need specific recommendations or further details on any particular tools, feel free to ask!	f	2025-07-03 21:41:52.50217-04
abd7c862-2f0e-47eb-aafa-921e2a409700	5e1db7fe-1339-4fcc-930b-2ced598ffd0f	I to build an AI agent easliy	t	2025-07-04 10:02:13.718946-04
28f90705-bf50-4e02-b121-b56f268254a3	5e1db7fe-1339-4fcc-930b-2ced598ffd0f	I can help you with that! What specific tasks or functions would you like the AI agent to perform?	f	2025-07-04 10:02:21.393228-04
b766ad8d-cae0-4143-8771-3281027ba639	9eedc4f7-8d4d-42eb-b76b-706e8c765d62	What is AI?	t	2025-07-11 12:13:51.769614-04
8fe2e621-c599-42ac-bf8a-f20f98c20b05	9eedc4f7-8d4d-42eb-b76b-706e8c765d62	{\n  "content": "AI, or Artificial Intelligence, refers to the simulation of human intelligence in machines that are programmed to think, learn, and solve problems. It encompasses a wide range of technologies and approaches, including machine learning, natural language processing, computer vision, and robotics, aimed at enabling computers to perform tasks that typically require human intelligence.",\n  "ads": [],\n  "mcp_necessity": "False",\n  "mcp_response": "",\n  "mcp_response_type": "",\n  "mcp_response_id": ""\n}	f	2025-07-11 12:13:56.694224-04
55691b5b-9ffd-4c7e-9084-b9290b6e69c0	a43cfeb7-509c-4d3d-b471-fc2495500afa	What is AI?	t	2025-07-11 12:15:23.647097-04
0dac74ce-8111-42cd-856c-6d0af59681f3	d6cc7341-da22-4c70-8838-a9a2d6ac9574	What is AI?	t	2025-07-11 12:16:57.479232-04
e077bc2c-9100-495f-9d13-a981e6939bcc	d6cc7341-da22-4c70-8838-a9a2d6ac9574	{\n  "content": "AI, or Artificial Intelligence, refers to the simulation of human intelligence in machines that are programmed to think, learn, and solve problems. It encompasses a wide range of technologies and approaches, including machine learning, natural language processing, computer vision, and robotics, aimed at enabling computers to perform tasks that typically require human intelligence.",\n  "ads": [],\n  "mcp_necessity": "False",\n  "mcp_response": "",\n  "mcp_response_type": "",\n  "mcp_response_id": ""\n}	f	2025-07-11 12:17:02.373328-04
e7d42930-1d14-42d4-86d6-d9e18fbd7e97	183f164e-9952-49b5-afce-68b61ec1219a	What is toolhouse?	t	2025-07-11 12:21:55.855942-04
59aa9fe9-8bac-4e3e-b60d-4bb9053cc9f7	183f164e-9952-49b5-afce-68b61ec1219a	{\n  "content": "Toolhouse is a platform or environment that provides various tools and functionalities to assist with tasks such as data retrieval, web search, content analysis, and more. It is designed to support advanced AI operations by offering a range of specialized tools for different purposes.",\n  "ads": [],\n  "mcp_necessity": "False",\n  "mcp_response": "",\n  "mcp_response_type": "",\n  "mcp_response_id": ""\n}	f	2025-07-11 12:22:01.160788-04
6d0fa708-6a3e-464d-b191-3793482a505d	f053db86-9c28-4409-8ae4-164abe71955e	What is AI?	t	2025-07-11 12:31:42.081376-04
ae5695c0-7dc1-43fe-8483-916e5fefa1db	f053db86-9c28-4409-8ae4-164abe71955e	{\n  "content": "AI, or Artificial Intelligence, refers to the simulation of human intelligence in machines that are programmed to think, learn, and solve problems. It encompasses a wide range of technologies and approaches, including machine learning, natural language processing, computer vision, and robotics, aimed at enabling computers to perform tasks that typically require human intelligence.",\n  "ads": "Discover the latest in AI technology! [Learn more about AI solutions](https://example.com/ai-solutions)",\n  "mcp_necessity": "false",\n  "mcp_response": "",\n  "mcp_response_type": "",\n  "mcp_response_id": ""\n}	f	2025-07-11 12:31:47.543087-04
\.


--
-- Data for Name: chat_sessions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.chat_sessions (id, creator_id, visitor_uuid, started_at, ended_at, run_id, session_type, last_activity_at, ad_frequency, revenue_vs_relevance, display_ad_similarity_threshold, min_seconds_between_display_ads) FROM stdin;
de646f6f-b8fe-4c55-a93a-77a6a0883c72	d64a4899-20e4-4ecd-a53e-057aceed54cf	8955b515-505a-407f-b613-11baeb804c52	2025-07-02 14:11:44.414913-04	\N	8ebb4956-cdca-4701-850c-605ba3012016	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
43d9a3f9-2bc1-4636-b925-ba3f4004c474	d64a4899-20e4-4ecd-a53e-057aceed54cf	64b8619f-c166-4796-aed4-27139ff7c6f1	2025-07-02 14:13:51.291857-04	\N	920bb6aa-832f-46cd-b70b-51c66b9a8ed6	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
0e4f69cf-93db-4452-b897-dd39df87f996	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-07-02 14:14:00.845799-04	\N	5d73da98-8cc0-448c-bff3-e78e99a81b56	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
44f10ab4-6f11-4099-b5c2-9d654690cb6e	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	fc12a0da-4b74-43c0-a32d-41eff65836b3	2025-07-03 11:39:46.482973-04	\N	0c84a1f7-a6a0-44b5-9885-08972803ece8	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
31222503-8def-4631-b6c1-57dfaed18c2b	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	82bda4df-4177-4d2b-8ba3-a93400e1f6cf	2025-07-03 11:43:37.710582-04	\N	8a288b0c-fadf-434f-afe1-b1ef89894c29	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
52a822c1-1945-4a39-9d1f-18cf060c5168	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	ce55a22a-9f90-4f1a-991a-670ac2b15193	2025-07-03 11:45:53.912664-04	\N	8c8f0aa8-d4fa-40ce-a246-870a00a4e1bf	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
b3a30668-1a87-4a6c-bb2d-d80a50414b97	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	be6fe138-3291-4fdd-9258-6211e16b21ac	2025-07-03 21:15:17.24051-04	\N	7325fb9b-7e8e-4abe-a013-6a6685aca956	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
64ece526-953c-4974-8948-f74e87cadda6	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	6b85f3eb-2e72-41d3-928d-f8ef4119b0ed	2025-07-03 21:15:33.259681-04	\N	bf926f28-3608-43a7-9fdb-8bf06c4d9d98	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
ba7c53b0-f10f-4914-b296-f939ce90fb0f	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	12ccd78d-3421-494e-be7f-38719ff10b7f	2025-07-03 21:15:41.678422-04	\N	07f9c5e7-7721-485f-8b53-0354d65816d5	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
ae7e9937-6716-484b-ad27-6372be336e62	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	ab455f70-dbdb-4e61-a438-20ef144123c5	2025-07-03 21:15:54.911074-04	\N	acd93634-db33-4ed2-b08e-789617057153	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
a0bba5a9-1926-432a-ac5a-71d59c84eb91	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	b9d8e2a8-052f-4c59-a903-2692cc28b231	2025-07-03 21:16:05.799769-04	\N	c1f49a61-4a10-4039-98f7-2a84e2841ccc	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
2ce1e6ac-d82e-49df-b59d-a3fe7ff861ce	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	d7e198a6-b0a0-4e8c-8adf-87f8034f9ca8	2025-07-03 21:34:37.615072-04	\N	0e00323a-175f-48b0-95f1-cedf116d1e8a	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
89839bcf-5ea7-44e4-9b6b-e440fa32e131	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	b1ba9f80-3376-45f5-83b5-724ff631c134	2025-07-03 21:34:49.791484-04	\N	82d2cde4-6bc3-402d-b691-608728614d0d	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
2c40d6b9-dd7d-44c7-9e27-7d83325a7c5a	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	06281ce8-d830-4e9c-99a1-48c554c3d346	2025-07-03 21:35:00.093535-04	\N	1545ccae-3ba8-4c53-bd55-515322ff9cdd	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
f938c92e-c1f7-4ee3-b54a-3e4d5e136c1e	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	354f1281-40e4-49f9-b2f3-4dd9123a091e	2025-07-03 21:35:13.17814-04	\N	f34ef2b3-140d-493e-814d-ed82f9bc9246	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
6384e4a0-b350-4fec-ad5d-e059dde70a40	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	72c84f97-e2f1-412a-bc89-2e1eed99b512	2025-07-03 21:35:25.320974-04	\N	edd6ec06-308a-4707-a4e0-fab3007ca03b	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
67c9565b-67ff-4a3a-b2c5-05ee9207b54b	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5c443f0-fa4f-4ada-81aa-e3f58b79cbe4	2025-07-03 21:38:36.200466-04	\N	972f9d73-8795-4ee1-b6a5-c221fe59b809	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
ff28a9da-ec91-42b6-9eb1-80bcb0d5c702	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e3d70cee-6ef9-4004-b570-36c4165549b6	2025-07-03 21:38:49.23682-04	\N	b63a9dca-e621-4921-ba0b-d47c88e9c3ce	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
d8cee115-cac0-4a98-9bd9-c4fdb2befc1c	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	76a633c5-e77e-4d8f-93ac-a60cf5bb2661	2025-07-03 21:38:59.424714-04	\N	fc80740e-4562-4fbd-ab17-0b7188bff7db	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
ee26f59a-57bf-4790-a944-f3f34b499162	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	b9bb2c25-7826-4dc3-9442-a686817b1d89	2025-07-03 21:39:12.565065-04	\N	2849c72e-4fa1-47ab-a135-a83931912e2b	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
d7039014-9648-447c-90c7-547157aeb43b	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	ab50a04f-f008-49ed-b067-510cddf74a01	2025-07-03 21:39:24.332301-04	\N	edafd077-6c9e-45c3-8efb-def438b2fc5d	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
8bb7b0a9-96d2-487f-9b52-4599fc9fbb79	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	4b5bb537-adc6-41f2-a0b4-b52780da4d65	2025-07-03 21:40:57.633746-04	\N	2a81ae3a-5697-4c04-aed5-0bbd4a164285	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
19841b52-0d7e-4a14-a709-7349f33bf1a3	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	d521ac3d-22d5-4b78-8d5b-9289794c4463	2025-07-03 21:41:08.358656-04	\N	f08d90ff-6471-4962-9260-c22105923295	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
ef2fc807-1d1f-4d18-87ef-359f1393598e	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	621acdeb-fcd9-450d-877d-3e007c2a7350	2025-07-03 21:41:18.312972-04	\N	e12073a4-4cfa-46c0-b352-61b4088b0df1	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
cf362298-d0b9-466b-89dc-f18da80903b4	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	fcebe2ae-6248-4b35-b5dc-72b5b15be43c	2025-07-03 21:41:34.418679-04	\N	c201ec70-fce0-4b9e-8cc3-07dbc758785b	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
4c3fdc51-349d-484e-8b30-1426c4924a34	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	23e16471-4345-44f6-bdf9-e17ca1aef211	2025-07-03 21:41:45.598846-04	\N	01101953-f7d0-46f2-9bf5-c5e55f1fecef	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
5e1db7fe-1339-4fcc-930b-2ced598ffd0f	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	\N	2025-07-04 10:02:13.708685-04	\N	a0a04aa4-ac63-4e4d-9d18-6517bab73ca7	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
9eedc4f7-8d4d-42eb-b76b-706e8c765d62	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	\N	2025-07-11 12:13:51.715564-04	\N	e3246cd0-aba7-4e18-b764-4645bb029097	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
a43cfeb7-509c-4d3d-b471-fc2495500afa	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	\N	2025-07-11 12:15:23.639242-04	\N	8b512fc4-4c71-439a-be75-f68cd6756159	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
d6cc7341-da22-4c70-8838-a9a2d6ac9574	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	\N	2025-07-11 12:16:57.466763-04	\N	9a7465be-2e19-4c39-822f-596cfe6d73d6	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
183f164e-9952-49b5-afce-68b61ec1219a	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	\N	2025-07-11 12:21:55.847555-04	\N	69e5465c-f3c6-470d-8b78-a4280515728d	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
f053db86-9c28-4409-8ae4-164abe71955e	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	\N	2025-07-11 12:31:42.072236-04	\N	aef231df-e7fa-4f0a-b59a-d9357a96e398	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
87e3c4e4-9ad2-4f03-8e7f-081ea4050703	32872c3f-b91d-4897-bd2b-b79286e6b97c	4edcd91b-ae10-40b7-9bfc-4af174fecee0	2025-07-13 21:45:57.880975-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
58eeeaa1-cd88-44e9-bc4c-eb50bc37428d	d64a4899-20e4-4ecd-a53e-057aceed54cf	1c0bab38-e46e-49b8-ae7d-256248612dec	2025-07-14 08:44:26.781753-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
36c398fd-7726-4534-acea-1fa83239e456	d64a4899-20e4-4ecd-a53e-057aceed54cf	a2204319-dc7a-49da-b286-227dee7c8b1b	2025-07-14 08:45:06.805518-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
2480c5ec-13ce-4f2d-a6d9-697f05aa095d	d64a4899-20e4-4ecd-a53e-057aceed54cf	67835539-73c5-49e0-9736-8c6b9a9cbe7b	2025-07-14 08:46:07.907112-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
896d6dc1-8f00-422c-92b4-5b8c92eb4231	d64a4899-20e4-4ecd-a53e-057aceed54cf	65432994-217f-43b0-aaeb-c38d7a728e58	2025-07-14 08:47:05.978385-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
efe2dc31-0045-47ca-b3ab-1add9e947753	d64a4899-20e4-4ecd-a53e-057aceed54cf	fdcab15c-4ea4-4d8c-8d78-36a79ebfbbcc	2025-07-14 08:47:44.00662-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
3f3daf8b-8e36-4dd2-a5df-0361300e19f8	d64a4899-20e4-4ecd-a53e-057aceed54cf	ac8b8f4d-572d-42e2-adcf-2d22d07b6448	2025-07-14 08:48:48.188219-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
702a74e5-1cc7-4980-b135-38d5a065cc84	d64a4899-20e4-4ecd-a53e-057aceed54cf	597fd96c-4e05-4986-8c8c-205d257071fc	2025-07-14 08:49:10.025516-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
0365d496-36d2-4a10-a690-b847c75a1c14	d64a4899-20e4-4ecd-a53e-057aceed54cf	dea7587b-8b67-41b8-9628-791c4d68f786	2025-07-14 08:49:55.888568-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
aad25d8c-202c-4e2d-b467-12e2a92f9cca	d64a4899-20e4-4ecd-a53e-057aceed54cf	d56e66f9-29d3-4461-9374-7996599d8c1b	2025-07-14 08:50:17.180142-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
e780b035-0d1f-469f-9df6-ba04447577b4	d64a4899-20e4-4ecd-a53e-057aceed54cf	ceb1e57d-b8c5-41aa-84c7-6126a82ae74b	2025-07-14 08:50:33.911039-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
4fdc783a-ebc0-4ff6-86c5-099be5a8ff49	d64a4899-20e4-4ecd-a53e-057aceed54cf	7f0e9439-a562-4f14-a418-056420984158	2025-07-14 08:51:42.186661-04	\N	\N	mcp	2025-08-11 16:09:55.716543-04	\N	\N	\N	\N
17744dc5-041a-41fa-a259-35d74abce249	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 16:24:01.433546-04	\N	\N	mcp	2025-08-11 16:24:01.433546-04	\N	\N	\N	\N
0839ab22-e816-41e8-a8b0-09615a9af50c	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 16:27:27.910024-04	\N	\N	mcp	2025-08-11 16:27:27.910024-04	normal	0.50	0.25	30
c0e3a982-1d63-4b49-bad3-70e94b757cd8	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 16:32:52.319157-04	\N	\N	mcp	2025-08-11 16:32:52.319157-04	normal	0.50	0.25	30
e32b92d2-b5f5-4a8b-bbf5-411440e60593	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 16:57:01.891529-04	\N	\N	mcp	2025-08-11 16:57:01.891529-04	normal	0.60	0.30	45
83cd360f-5f4b-4290-aab3-a5b149f9b8fa	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 16:57:58.704627-04	\N	\N	mcp	2025-08-11 16:57:58.704627-04	normal	0.60	0.30	45
dcf438f4-0e44-4625-95b5-9f24a290e759	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:04:32.52157-04	\N	\N	mcp	2025-08-11 17:04:32.52157-04	normal	0.60	0.30	45
570caf35-b9ef-4ea2-b0ad-6211b2de7c88	d64a4899-20e4-4ecd-a53e-057aceed54cf	987fcdeb-51a2-43d1-9c4f-123456789abc	2025-08-11 17:04:57.246108-04	\N	\N	mcp	2025-08-11 17:04:57.246108-04	high	0.80	0.30	45
fa820f26-eb8a-4cd4-9b98-068f76812cff	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:10:19.508731-04	\N	\N	mcp	2025-08-11 17:10:19.508731-04	normal	0.60	0.30	45
dcaab217-4bbe-4b2f-9428-c667519912fb	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:11:18.56623-04	\N	\N	mcp	2025-08-11 17:11:18.56623-04	normal	0.60	0.30	45
fb1c6ef7-9d27-4a76-aedc-8078aac81d71	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:17:42.286283-04	\N	\N	mcp	2025-08-11 17:17:42.286283-04	normal	0.60	0.30	45
140892d7-e913-4211-9ad4-e26d56657fe6	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:18:25.934808-04	\N	\N	mcp	2025-08-11 17:18:25.934808-04	normal	0.60	0.30	45
279b66c1-181d-4672-b139-a4e3e76b168b	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:19:21.270396-04	\N	\N	mcp	2025-08-11 17:19:21.270396-04	normal	0.60	0.30	45
59804079-3212-45d2-8629-68ff773a622f	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:19:51.530557-04	\N	\N	mcp	2025-08-11 17:19:51.530557-04	normal	0.60	0.30	45
a5b0d78b-7a07-49b1-846b-ef23ae317976	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:20:32.32496-04	\N	\N	mcp	2025-08-11 17:20:32.32496-04	normal	0.60	0.30	45
efefefad-77aa-432b-8e77-09eae9f76220	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:20:59.614378-04	\N	\N	mcp	2025-08-11 17:20:59.614378-04	high	0.90	0.30	45
9a0efa54-7ac0-4ff4-88c4-78944f1608d9	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:21:24.573067-04	\N	\N	mcp	2025-08-11 17:21:24.573067-04	normal	0.60	0.30	45
1cbc31b7-a37d-4dfe-a212-fc59ea5c3378	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:22:04.134244-04	\N	\N	mcp	2025-08-11 17:22:04.134244-04	normal	0.60	0.30	45
8a2bfb43-406c-4397-995e-54035d00e187	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:22:04.682934-04	\N	\N	mcp	2025-08-11 17:22:04.682934-04	\N	\N	\N	\N
ef3f40c4-a23f-456a-ad94-6204d610d765	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:22:04.701122-04	\N	\N	mcp	2025-08-11 17:22:04.701122-04	\N	\N	\N	\N
e5364d91-c937-4191-b1b6-a6e7396b84a5	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:22:04.72338-04	\N	\N	mcp	2025-08-11 17:22:04.72338-04	\N	\N	\N	\N
458aa4b8-30e8-499a-8df7-039aa37a2784	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:22:04.722404-04	\N	\N	mcp	2025-08-11 17:22:04.722404-04	\N	\N	\N	\N
2397d908-5f51-48d2-a455-e7a1c1020fc7	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:22:04.72032-04	\N	\N	mcp	2025-08-11 17:22:04.72032-04	\N	\N	\N	\N
b37f6dba-420c-412c-9e11-7e7428e9737f	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:22:04.72958-04	\N	\N	mcp	2025-08-11 17:22:04.72958-04	\N	\N	\N	\N
486b3800-7473-4b27-bbaf-9c168094b024	d64a4899-20e4-4ecd-a53e-057aceed54cf	\N	2025-08-11 17:22:04.740301-04	\N	\N	mcp	2025-08-11 17:22:04.740301-04	\N	\N	\N	\N
819b4810-d7fe-4d1c-8f81-bf04f90d7b6b	d64a4899-20e4-4ecd-a53e-057aceed54cf	f91bb9f9-2c45-4936-a4fe-2c5195588e9c	2025-08-12 14:47:55.069956-04	\N	\N	mcp	2025-08-12 14:47:55.069956-04	\N	\N	\N	\N
\.


--
-- Data for Name: content; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.content (id, creator_id, title, content, created_at, updated_at, deleted_at, status) FROM stdin;
24416f45-db3c-4a52-9a74-ed863bb2eecd	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	Gemini 2.5 unleashed	Welcome back, Superhuman. You can now apparently build a lightweight Netflix clone with nothing more than an AI agent and some well-crafted prompts. And: Tech CEOs are finally starting to admit what we’ve all suspected: AI is coming for some of our jobs — but it might unlock even better opportunities in the process.\n\nAlso today: Learn how to create product videos with Higgsfield, and get the latest AI tools, prompts, and trending social media posts.\n\nTODAY IN AI\n\nAdobe is rolling out a series of new AI-powered updates for Firefly. Source: Adobe\n\n1. Google drops major Gemini 2.5 updates: The search giant revealed that Gemini 2.5 Pro, its most powerful model, is now out of preview and all set for developers to build on. The same is true for its smaller sibling, Gemini 2.5 Flash, which is designed for “fast all-around help.” Finally, a new model called 2.5 Flash-Lite is even speedier while beating its predecessor across math, science, and coding. It can also be assigned different “thinking” budgets if you want it to take on more complex tasks without jumping to the full Flash model.\n\n2. Open-source agent leaps to the front of the pack: Shanghai’s MiniMax just released a new model called M1 that features an enormous 1M-token context window — theoretically big enough to process an entire collection of books, compared to GPT-4o’s novel-length limit. It also edges out DeepSeek’s R1, despite that model getting a major upgrade only a few weeks ago. And it can supposedly handle everything from building a Netflix clone to whipping up a stock dashboard on its own.\n\n3. New mobile app unlocks on-the-go video generations: Adobe just unveiled a mobile version of Firefly, its commercially-safe image and video generation platform. It’s also rolling out Boards, an AI-powered digital mood board that can help you piece together creative ideas — now with video-gen folded in. Plus, you can access just about every major third-party video and image model inside Firefly, including newcomers from Luma, Runway, and Ideogram, as well as staples from Google and OpenAI.\n\nFROM THE FRONTIER\nAI is already reshaping the workplace\n\nNearly 20% of American workers use AI on a “frequent” basis. Source: Gallup\n\nThe US’s second-largest employer just dropped the hammer. In a new memo to his 1.5M+ employees, Amazon CEO Andy Jassy revealed that the company will likely see some job cuts in the near future as generative AI floods “virtually every corner of the company.”\n\nBut it’s not as grim as it sounds: Jassy said that while some positions are bound to be automated, other types of jobs will open up. Some of the best ways to prepare: “Be curious about AI, educate yourself, attend workshops and take trainings, use and experiment with AI whenever you can, participate in your team’s brainstorms.”\n\nA new Gallup poll suggests many of us are already well on our way: About 40% of American employees have used AI at least a few times in the past year, up from just 21% the year before. Meanwhile, nearly one in five employees count themselves as frequent AI users, relying on LLMs at least a few times a week for work. (A new Microsoft report has some tips to help ease the transition.)\n\nWhat it means: In the past few months, we’ve finally seen CEOs be more upfront about AI’s impact on jobs. While that transparency can be daunting, it’s also an exciting time for the workforce. We have an active role in reshaping our daily workflows and can proactively create the jobs we envision.\n\nAI & TECH NEWS\nEverything else you need to know today\n\nKrea’s new image model breaks new ground in the photorealism department. Source: Krea\n\n📸 Sharper Image: AI creator platform Krea is giving everyone access to its new image model, Krea 1, which can generate photorealistic shots while avoiding the typical “AI look” that affects its competitors. You can try it here.\n\n🧑‍💻 Ultra Upsell: Cursor unveiled a new $200/month Ultra plan that gives power users 20x the usage of its $20/month Pro tier. The move could help parent company Anysphere boost revenue following its $9.9B valuation earlier this month.\n\n📱 ‘Text’-to-Image: You can now generate images by sending a prompt to 1-800-ChatGPT inside WhatsApp. Plus, OpenAI is bringing reusable prompts to the API, letting you easily “reuse, share, save, and manage your prompts” — or even optimize them with the click of a button.\n\n👓 Clear Vision: Meta and glasses-maker EssilorLuxottica are teaming up with Oakley and Prada to create spin-offs of their AI-powered smart glasses. Oakley’s version will reportedly cost $360, featuring new weather resistance upgrades, while the Prada variant is still under wraps.	2025-06-21 20:56:23.484783-04	2025-06-21 20:56:23.484783-04	\N	published
04c3d6df-919c-4677-b993-dfaeccb3045b	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	Midjourney video model is finally here	Welcome back, Superhuman. It’s finally here. If you’ve been dabbling in AI image generation since the early days, you probably know that Midjourney is a fan favorite. But other AI labs have beaten Midjourney to video models over the last year. The company’s long-awaited video model is here at long last — and packs a serious punch.\n\nAlso: Sam Altman makes some big allegations, Meta continues its spending splurge, and learn how to find hidden insights with today’s prompt.\n\nTODAY IN AI\n\nClick here to watch Midjourney’s new video generation model V1 in action. Source: Midjourney\n\n1. Midjourney launches its first AI video generation model: The startup just dropped V1, which lets you turn any image into a set of 4 five-second video clips. The model can extend clips up to 21 seconds and allows users to tweak camera movement and animation styles. At $10/month, it’s significantly cheaper than other video generation models in the space, and according to Wharton professor Ethan Mollick, it can generate video styles that are hard to achieve with other video creation tools.\n\n2. Sam Altman drops GPT-5 timeline: In a podcast interview, the OpenAI CEO shared that GPT-5 is coming “probably sometime this summer.“ The model is expected to come with enhanced reasoning and agentic capabilities. Altman also alleged that Elon Musk tried to use his influence in government to compete unfairly against OpenAI. In a separate interview, Altman also claimed that Meta is offering OpenAI’s top employees $100M bonuses to lure them away.\n\n3. Meta reportedly continues its aggressive talent acquisition spree: Not to be deterred by allegations of $100M pay packages, the social media giant is reportedly courting former GitHub CEO Nat Friedman and investor Daniel Gross to join its leadership team. Meta may also potentially buy out part of their venture fund NFDG. The duo has backed major AI startups like Perplexity, Eleven Labs, and Safe Superintelligence.\n\nIN THE KNOW\nWhat’s trending on socials and headlines today\n\n🧠 Brain Drain: MIT just ran a study that measures the effects of ChatGPT on student brains and the results don’t look great.\n\n✨ Reality Check: Someone asked ChatGPT the top 10 things humanity should know and put the chatbot’s response up on Reddit in a post that has since blown up.\n\n✍️ Reality Filter: A ChatGPT and Gemini user claims to have created a prompt that stops these chatbots from hallucinating and gaslighting you.\n\n💡 Builders Delight: Andrej Karpathy's keynote at YC’s AI Startup School is blowing up. It’s a must-watch if you’re building with AI.\n\nGoogle just dropped a new “Search Live” feature for its AI mode, letting you hold full conversations and chat back and forth with search results. Users can now ask follow-up questions out loud and get AI-generated audio responses in return.\n\nHiggsfield AI launched Canvas, a new image editing model that lets users paint products directly onto photos. Handy for marketers, designers, and creators.\n\nOpenAI is rolling out "Record Mode" for ChatGPT Pro users, allowing you to record, transcribe, and summarize your meetings. The feature is available on the macOS desktop app.\n\n	2025-06-21 20:56:23.484783-04	2025-06-21 20:56:23.484783-04	\N	published
9d7cc234-ae88-473c-827d-ba5e550421fe	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	Robotics Special Waymo eyes the Big Apple	Robotics Special: Waymo eyes the Big Apple\n\nWelcome back, Superhuman. Researchers in Italy dropped the world’s first flying humanoid robot this week. And robotaxis are looking to gradually expand their footprint across the US, with Alphabet-owned Waymo now eying a move to the Big Apple.\n\nP.S. The Robotics Special is designed to help you stay on the cutting edge of the latest breakthroughs and products in the industry. Our regular AI and Tech updates will resume as usual on Monday.\n\nThe most important news and breakthroughs in robotics this week\n\nClick here to watch the world’s first flying humanoid robot lift off the ground. Source: Italian Institute of Technology\n\n1. Waymo’s self-driving cars might make their way to NYC: The company has put in an application to test its driverless cars in New York City — one of the first autonomous vehicle (AV) companies to request approval for testing in the notoriously chaotic streets of Manhattan. The robotaxi company would initially operate with trained specialists behind the wheel since state law doesn't allow fully autonomous drives yet. The move comes as Tesla prepares to kick off its limited robotaxi operations in Austin.\n\n2. Hexagon taps Nvidia Robotics to deploy its humanoid robot: The company has unveiled AEON, a humanoid robot built with Nvidia’s simulation platform for manufacturing and logistics tasks. The industrial bot hopes to tackle critical labor shortages by performing reality capture — automatically scanning assets and environments to generate precise 3D models. Using Nvidia’s Omniverse platform, AEON mastered core locomotion skills in just 2-3 weeks instead of the typical 5-6 months.\n\n3. Researchers claim they’ve built the ‘first flying humanoid robot’ : Italian researchers have unveiled the iRonCub3, a jet-powered humanoid robot that they claim successfully hovered to about 50cm off the ground during its first test flight. Not exactly breaking altitude records, but still a significant leap. Unlike traditional drones, the robot must balance an entire humanoid body with movable limbs while adapting to complex, ever-changing aerodynamics. See it in action here.\n\nROBOTS IN ACTION\nHow robots are transforming the world around us\n\nDr. Kenneth Liao performs the first successful, fully robotic heart transplant in the US. Source: Baylor College of Medicine\n\nHeart Hack: Houston surgeons have performed the first fully robotic heart transplant in the US without cracking open the patient's chest. Instead of the traditional method of breaking the breastbone, doctors made small incisions in the abdomen, using robotic tools to remove the diseased heart and implant a donor organ.\n\nGas Guardian: A single undetected gas leak can cost facilities over $57,000 per year and pose a major safety risk in petrochemical plants. Now, Swiss robotics company ANYbotics has equipped its ANYmal robot with gas leak detection capabilities, enabling the quadruped to pinpoint invisible leaks that manual inspections often miss.\n\nBlade Runner: KUKA has unveiled the Catonator, a remote-controlled robotic saw armed with 2,000mm blades that can slice through steel, concrete, and aerospace composites with 0.1mm precision. It could potentially automate precision cutting tasks while eliminating emissions and improving worker safety in heavy industry applications.\n\nINDUSTRY SNAPSHOT\nEverything else you need to know this week\n\nSource: Reuters\n\nHere are the biggest developments in the robotics space that you should know about:\n\nTesla has been asked by Democratic lawmakers to put off its robotaxi launch until September, when new regulations with stricter state oversight take effect.\n\nAnduril is joining hands with German giant Rheinmetall to build military drones for European markets — a shift toward faster innovation in European defense.\n\nA recent Gallup poll shows that 15% of US workers believe that AI or robots may likely replace their jobs.\n\nAmazon's Zoox just opened its first production facility in Hayward, California, where it eventually expects to build over 10,000 electric AVs annually.\n\nEngineAI has open-sourced a dev suite designed to accelerate humanoid robot creation by removing technical barriers for startups and researchers.\n\nUS startup Skydweller Aero has partnered up with French defense company Thales to deploy a solar-powered drone that can stay in flight for a whole month.\n\nPrismaX has launched with $11M to solve one of the biggest bottlenecks in robotics — a lack of high-quality training data for AI models.\n\nROBOT OF THE WEEK\nA robot that caught our eye this week\n\nSource: Beatbot\n\nBeatbot’s AquaSense 2 is making waves as a Roomba for your swimming pool.\n\nThe robotic pool cleaner uses HybridSense AI mapping, 27 sensors, and 11 motors to clean floors, walls, waterlines, and the water surface automatically while also offering water clarification. It can take on pools up to 3,875 square feet and runs for up to 10 hours on a single charge for surface cleaning.\n\nYou can check it out here.\n\nROBO REEL\nWatch: Inventor builds real-life Transformer that shape-shifts into a ride\n\nBruton's robot is a feat of practical engineering, designed with eagle-eyed detail. Source: James Bruton / YouTube\n\nIt was only a matter of time.\n\nIn what was every 90s kid’s childhood dream, British inventor James Bruton has built a rideable Transformer robot that actually shape-shifts from humanoid to vehicle. Unlike other transformer projects that leave no room for passengers, Bruton's creation can carry a human rider at functional speeds.	2025-06-21 20:56:23.484783-04	2025-06-21 20:56:23.484783-04	\N	published
55992b0a-c309-40de-8b81-67fd7536ea54	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	Tiny teams huge payoff	Welcome back, Superhuman. It might be time to change your password. Researchers claim they’ve uncovered one of the largest data hacks ever recorded. If confirmed, it’d mean up to 16B of our private credentials from platforms like Google and Apple might be compromised.\n\nAlso today: Learn how to generate ChatGPT images in WhatsApp, and get the latest AI tools and trending social media posts.\n\nTODAY IN AI\n\nMiniMax is going after rivals like OpenAI and Butterfly Effect with a browser-based agent. Source: MiniMax\n\n1. You can now try MiniMax’s general agent for yourself: The Alibaba-backed startup is bringing its models’ reasoning capabilities to the masses. MiniMax Agent lets you spin up coding projects, reports, and slideshows alongside an autonomous AI teammate that seems at least on par with fellow Chinese counterpart Manus. For inspiration, you can scroll down to see what others have created, like a London airspace tracker, a virtual museum tour, and an SEO dashboard — complete with the prompts they used.\n\n2. Little-known startup races to fill Scale AI-shaped hole: With Meta purchasing a 49% stake in Scale and major players like OpenAI and Google heading for the door, an obscure startup called Surge AI is stepping out of the shadows as a worthy replacement. Like Scale, the 110-person company labels data for training frontier models. But it brought in $1B last year, fully bootstrapped, while $29B-valued Scale made only $870M in the same period. Surge is just one of a growing number of data-labeling startups that could stand to benefit from the Scale shakeup.\n\n3. MIT builds model that can continually teach itself: One thing that separates us from AI is that we have the ability to pick up new information and adjust our worldview accordingly. But that skill might not be exclusive to humans for long. MIT researchers developed a technique called Self Adapting Language Models (SEAL) that lets LLMs adjust their own parameters as they learn. The approach boosted the performance of Meta’s Llama and Alibaba’s Qwen, although pushing the models too much can actually lead them to start forgetting things.\n\nFROM THE FRONTIER\nAI is fueling a ‘solopreneur’ boom\n\nAI is getting so good, it can now replace real-life hosts. Source: CNBC/Screenshot\n\nA solo developer just sold his six-month-old ‘side-project’ for $80M: Maor Shlomo’s vibe-coding platform Base44, which helps non-programmers design their own software, was acquired by Wix as it looks to add more AI features to its website-building platform.\n\nWhile Shlomo’s startup didn’t stay “solo” for long (it eventually grew to include nine employees in total), its rate of growth and profitability, generating $189,000 of profit in May alone, would have been unheard of even a couple of years ago.\n\nAnother surprising application: Two AI avatars, trained on a real-life influencer and his co-host in China, just raised $7.65M in just seven hours via a livestream where they showed off different products. That’s allegedly more than the real-life hosts had managed during previous streams.\n\nThe big takeaway: AI is making startups smaller and smaller, as founders start to hand off increasingly complex tasks to agents. It’s to the point where a solo unicorn — a single-person startup with at least a $1B valuation — doesn’t sound quite so far-fetched anymore. To keep up, bigger corporations will need to carve out small, nimble teams where employees can experiment and put AI to use in unexpected ways.\n\nAI ACADEMY\nHow to generate ChatGPT images in WhatsApp\n\nOpen WhatsApp on your phone.\n\nSend the message “Link my WhatsApp with ChatGPT” to 1-800-ChatGPT.\n\nYou’ll receive a link—tap it to connect your WhatsApp with your ChatGPT account\n\nNow you can prompt ChatGPT within WhatsApp to generate images for you.\n\nSample Prompt: Can you create me a white fluffy cat made of rice wrapped in a strip of seaweed around its stomach\n\nWait a few seconds, and ChatGPT will generate an image for you.\n\nIN THE KNOW\nWhat’s trending on socials and headlines today\n\nWatch what happened when a UCLA graduate showed off all his ChatGPT-generated final projects during his graduation ceremony.\n\n♟️ Masterful Move: Duolingo built a full chess course from scratch with just two employees and the AI coding tool Cursor. Here’s how.\n\n🔁 Mother Lode: This mega-thread of X users sharing their coolest model context protocol (MCP) integrations is a goldmine of good ideas.\n\n🕵️ The Plot Thickens: Are all LLMs converging around the same personality and responses? OpenAI cofounder Andrej Karpathy is on the case.\n\n🤫 Paper Trail: Two nonprofits just released a huge trove of documents that supposedly reveal some of OpenAI’s biggest secrets. Podcast host Rob Wiblin rounded up the most shocking details, although skeptics are already calling them into question.\n\nOpenAI is rolling out Record Mode, which can transcribe and summarize your meetings and thoughts, for all Pro, Enterprise, and Edu users.\n\nPerplexity will now let you generate videos with text prompts when you tag “@AskPerplexity” on X. Here’s a thread with some user-submitted examples.\n\nResearchers at OpenAI say they’ve spotted certain “internal patterns” similar to brain activity that flare up before a model misbehaves — a breakthrough that could help us build safer LLMs in the future.\n\nPROMPT STATION\nLinkedIn Profile Optimizer\nPrompt: <Role>\nYou are a top LinkedIn Profile Strategist who helps professionals turn average profiles into powerful tools for career growth, visibility, and credibility. <Role>\n\n<Context>\nWith 95% of recruiters using LinkedIn and just 7–15 seconds spent scanning a profile, a strong profile can unlock major opportunities. Most professionals fail to stand out or clearly communicate their value. <Context>\n\n<Instructions> Ask the user to share:\nCurrent headline\nAbout/summary section\nExperience descriptions\nSkills section\nRecent content/activity\nCurrent goals\nTarget audience (recruiters, clients, peers, etc.)\n\nThen, perform a detailed audit and provide:\nHeadline Transformation – 3 keyword-optimized, high-impact alternatives\nSummary Rewrite – Rewritten using the Hook–Story–Offer framework\nExperience Entry Fix – Convert one duty-based entry into a results-driven version\nSkills & Endorsements – Optimization strategy for relevance and credibility\nContent Strategy – 30-day calendar with 5 viral post ideas\n\nAlso include:\nImplementation Priority Guide – Steps in order of impact\nPerformance Metrics – Track views, search appearances, and engagement <Instructions>\n\n<Constraints> Keep suggestions tailored, actionable, and authentic. Avoid vague advice or unrealistic claims. Don’t request private info beyond LinkedIn content. <Constraints>\n\n<Output_Format>\nLINKEDIN PROFILE AUDIT\n\nCurrent Profile Strengths\nCritical Improvement Areas\nStrategic Recommendations (items 1–5 above)\nImplementation Priority Guide\nPerformance Measurement <Output_Format>\n\n<User_Input> Ask the user for the 7 LinkedIn details listed above before starting your audit. <User_Input>	2025-06-21 20:56:23.484783-04	2025-06-21 20:56:23.484783-04	\N	published
70dc870f-f1bf-4291-98fd-25de3d96e3fe	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	Veo dethroned by Chinese rivals	Welcome back, Superhuman. OpenAI wants out. A new report suggests its once unshakeable partnership with Microsoft could be in jeopardy. Plus: A surprise video model leaps past Veo 3, and Adobe has a plan to help companies boost their visibility on AI chatbots and browsers.\n\nAlso today: Learn how to automate your web browsing with AI, and get the latest AI tools and trending social media posts.\n\nTODAY IN AI\n\nByteDance’s Seedance model just claimed the top spot in a popular benchmark.\n\n1. Two new video models jump past Veo 3 on major benchmark: Since Google’s Veo 3 release last month, it’s been the undisputed champion of VLMs — even making its way to primetime TV spots and Hollywood-backed short films. But its lead didn’t last for long: Artificial Analysis’ crowd-sourced leaderboard just ranked ByteDance’s Seedance 1.0 ahead of Veo across multiple categories. Meanwhile, MiniMax just revealed that a mysterious VLM known as “Kangaroo,” which beats Veo in image-to-video, is actually a brand-new model called Hailuo 02. The shakeup proves that Chinese AI companies are managing to stay competitive with their US counterparts.\n\n2. TikTok unveils new AI video tools: ByteDance just gave marketers an entirely new way to promote their products on TikTok. Advertisers can now generate five-second clips with either text or image prompts, then stitch them together to “bring a full product catalog to life.” For example, you can upload an image of a car, and then generate a video of it driving through a desert landscape. You can also prompt AI avatars to talk about your product and show it off, or even model your brand’s clothing.\n\n3. Adobe is helping brands brace for AI’s search shakeup: Retail sites saw a staggering 3,500% spike in traffic coming from generative AI sources in the past year. But while consumers are quickly embracing chatbot-based shopping, analytics tools have struggled to keep up. Adobe’s new LLM Optimizer aims to fix that — helping companies track how their content performs across AI platforms. It also boosts discoverability, sort of like SEO for LLMs, so your products are more likely to surface in AI-driven searches.\n\nFROM THE FRONTIER\nReport: Microsoft and OpenAI face a bitter breakup\n\nOpenAI and Microsoft’s close relationship could be souring. Source: Analytics India Magazine\n\nIt looks like Microsoft and OpenAI’s six-year partnership — one of the closest collaborations in the industry — might have finally reached a tipping point.\n\nIt was a match made in heaven: As far back as 2019, Microsoft has been giving OpenAI cloud access and billions in investments in exchange for exclusive rights to the ChatGPT-maker’s models. But now that OpenAI has become a massively successful tech company in its own right, it wants more independence and flexibility.\n\nHow so? OpenAI has been trying for months to transform into a public-benefit corporation, giving it a chance to turn a profit and accelerate its growth. The one thing holding it back: Microsoft won’t budge on the details out of fear it’ll get burned in the process.\n\nHigh Stakes: According to the Wall Street Journal, the feud has gotten so heated that OpenAI is now considering going public with its accusations. It could also ask the federal government to investigate Microsoft for antitrust violations.\n\nNot so fast: In a joint statement, both companies agreed they’re “optimistic we will continue to build together for years to come,” hinting that there might still be time to smooth things over.\n\nAI & TECH NEWS\nEverything else you need to know today\n\nA team of researchers used GPT-4.1 and o3-mini-high to shave off years of research time. Source: Imagen\n\n📊 Hype Train: Reddit launched a pair of AI tools that let advertisers track what’s trending in different subreddits and test-drive new campaigns before rolling them out on the platform.\n\n🔍 Data Dash: Researchers from Harvard, MIT, and other institutions reportedly saved the equivalent of 12 years of work by using OpenAI’s GPT-4.1 and o3-mini-high to automate a systematic review of medical research.\n\n📱 Price of Progress: Meta is bringing ads to WhatsApp’s “Updates” tab, which gets around 1.5B visitors per day, as the social media giant races to recoup the $14.3B it recently invested in Scale AI.\n\n💬 Missing Link: ElevenLabs now supports MCP (model context protocol), meaning you can now build voice agents that connect to Salesforce, HubSpot, and Gmail without any setup.\n\nSOCIAL SIGNALS\nWhat’s trending on socials today\n\nClick to see how a Redditor created a concept for a Ghibli-style video game.\n\n📚 Takes a Village: Anthropic just revealed how it built its own multi-agent research system, which “beat single agents by up to 90%+ on some complex tasks.” AI builder Elvis Saravia has some highlights if you don’t have time to read the whole thing.\n\n🐊 Cold-Blooded Content: A viral post claims Anthropic is sponsoring an albino alligator named Claude at the California Academy of Sciences. There’s even a livestream where you can watch Claude “as he lounges, swims, and snoozes” in his swamp.\n\n🎧 Sound of Success: Clever TikTok users are allegedly racking up tens of millions of followers by creating ASMR videos — like slicing through glass fruits and molten lava — using Veo 3’s new native audio features.\n\n🧑‍💻 Beyond Buzzwords: LinkedIn cofounder Reid Hoffman just shared his advice for how to prepare for the AI wave, beyond just learning how to prompt engineer and vibe-code.\n\nPROMPT STATION\nSimplify and summarize long articles\nPrompt: You are a reading assistant. The user will provide you with an article to read. Please thoroughly read the article and generate a guide and a simplified, easy-to-read version of the article with the following requirements:\n\n## Your output:\n\nMind Map: First, generate a mind map for the entire guide.\n\nSummary: Next, provide a summary of the entire text, limited to 400 words.\n\nSimplified Article: Then, present your rewritten simplified and easy-to-read version of the article.\n\n## Requirements for Rewriting:\n\nWord Count: Compress the word count to half of the original, and ensure it does not exceed 3,000 words.\n\nAuthor’s Tone: Simulate the original author's tone.\n\nStructure: Maintain the original structure, retaining all levels of headings.\n\nFormatting: Format the output to ensure a visually appealing layout and ease of reading.\n\nVisual Elements: Insert tables, charts, diagrams, SVGs, and other visual elements in appropriate places to enhance readability.\n\nSource: r/ChatGPTPromptGenius	2025-06-21 20:56:23.484783-04	2025-06-21 20:56:23.484783-04	\N	published
2c57be63-ce62-4569-911a-c2c8950f8194	d64a4899-20e4-4ecd-a53e-057aceed54cf	AIContinuousRapidEvolution	AI Continues Rapid Evolution: From Healthcare to Cybersecurity, Latest Developments Unfold\nThe past few days have seen a flurry of activity in the world of Artificial Intelligence, with breakthroughs and significant advancements emerging across diverse sectors. From innovative applications in healthcare and education to pressing concerns around security and ethical considerations, AI continues its relentless march forward, reshaping industries and prompting important societal discussions.\n\nOne of the most notable stories centers on the rapid adoption of AI by the U.S. Food and Drug Administration (FDA). The agency has launched "INTACT," its first agency-wide AI tool, designed to enhance operational efficiency, streamline regulatory processes, and improve risk assessment. This marks a significant step towards AI-driven government transformation, demonstrating a commitment to leveraging AI for public service.\n\nHowever, the proliferation of AI also brings new challenges. Cybersecurity researchers have raised alarms about new malicious AI variants based on WormGPT, including strains built on popular models like Grok and Mixtral. These tools are being weaponized to automate phishing attacks and malware creation with advanced precision, highlighting the urgent need for stronger AI safety and security protocols.\n\nEducation is another area witnessing significant AI integration. Mississippi has partnered with Nvidia to launch a statewide AI education initiative for middle and high school students, aiming to prepare the next generation for technology careers. Similarly, Google continues its investment in AI for education, offering free access to tools like Gemini Advanced for college students and expanding AI literacy programs.\n\nBeyond government and education, individual achievements are also making headlines. A remarkable example is 16-year-old Pranjali Awasthi, who founded Delv.AI, a $12 million AI research startup focused on making academic data more accessible with Large Language Models (LLMs). Her inspiring story underscores the potential for young innovators to contribute significantly to the AI landscape.\n\nOn the ethical front, Wikipedia editors are pushing back against the increasing use of AI-generated content on the platform, citing concerns about accuracy, tone, and proper citation. This backlash reflects broader tensions between human moderation and machine-generated information, prompting discussions about maintaining quality and trustworthiness in the age of AI. Even religious leaders are weighing in, with Pope Leo XIV expressing concerns about AI's impact on youth development and urging developers to embed human dignity in AI design.	2025-06-22 10:36:59.578249-04	2025-06-22 10:36:59.578249-04	\N	published
35059838-9019-4ac4-900d-f9cdab29ee11	d64a4899-20e4-4ecd-a53e-057aceed54cf	The Evolving Landscape of AI Regulation	The Evolving Landscape of AI Regulation: A Global Shift Towards Economic Harness\nToronto, ON – June 22, 2025 – The global conversation around Artificial Intelligence (AI) regulation is undergoing a significant pivot, moving away from an exclusive focus on safety and warnings towards a more concerted effort to harness AI's economic benefits. This shift was underscored by Canada's new Minister of Artificial Intelligence and Digital Innovation, Evan Solomon, in a recent address, signalling a broader trend among nations.\n\nMinister Solomon, in his inaugural speech, emphasized that Canada will no longer "over-index on warnings and regulation," but instead prioritize ways to maximize the economic advantages offered by AI. While acknowledging the need to protect data and privacy, he suggested that a rigid, singular approach to AI regulation is impractical given the rapid pace of technological development and the varying interests of global players. "The United States and China have no desire to buy into any constraint or regulation," Solomon stated, highlighting the challenges of unilateral regulatory efforts.\n\nThis sentiment echoes a broader shift observed internationally. The initial global summits on AI safety, which heavily emphasized existential risks, are giving way to forums with a wider scope, now encompassing adoption strategies and economic integration. For instance, the recent AI Action Summit in Paris saw a distinct pushback against overly restrictive European regulatory efforts from the US Vice-President.\n\nCanada's new approach aims to foster its domestic AI industry, drive adoption across various sectors, and ensure Canadian trust and sovereignty over the technology. This includes government investments in data centers and research, intellectual property protection, and a strong focus on commercialization. The goal is to champion Canadian AI companies and encourage small and medium-sized enterprises to embrace AI, positioning the country to lead in this "Guttenberg moment" of technological revolution.\n\n\nWhile the need for ethical guidelines and safeguards remains, particularly concerning data protection and privacy, the overarching message from many governments is clear: the future of AI lies in defining, shaping, and leading its transformative potential for economic growth and innovation, rather than solely attempting to constrain it.	2025-06-22 10:36:59.578249-04	2025-06-22 10:36:59.578249-04	\N	published
\.


--
-- Data for Name: content_status_values; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.content_status_values (value) FROM stdin;
draft
published
archived
\.


--
-- Data for Name: creator_advertiser_blocklists; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.creator_advertiser_blocklists (creator_id, advertiser_id, created_at) FROM stdin;
\.


--
-- Data for Name: creator_affiliate_codes; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.creator_affiliate_codes (id, creator_id, advertiser_id, affiliate_code, affiliate_program, is_active, commission_rate, currency, notes, created_at, updated_at, deleted_at) FROM stdin;
c8b402cc-12c6-41fe-9300-94f8206df2ea	d64a4899-20e4-4ecd-a53e-057aceed54cf	ed6822db-9052-4c76-8fd2-726115bd8c8a	EARNLAYER-12345	amazon	t	0.0500	USD	Amazon Associates affiliate code for tech products	2025-07-23 15:19:11.292353-04	2025-07-23 15:19:11.292353-04	\N
135d3670-14f2-46c9-8622-a94abfc049ea	d64a4899-20e4-4ecd-a53e-057aceed54cf	ed6822db-9052-4c76-8fd2-726115bd8c8a	ref=earnlayer_new	direct	t	0.0800	USD	New direct affiliate program	2025-08-06 10:09:59.138904-04	2025-08-06 10:09:59.138904-04	\N
f9b85952-d2e9-46de-8c96-50bf67bd0065	d64a4899-20e4-4ecd-a53e-057aceed54cf	ed6822db-9052-4c76-8fd2-726115bd8c8a	EARNLAYER-TEST-UPDATED	test	t	0.0500	USD	Test affiliate code for URL appending	2025-07-23 15:32:34.449087-04	2025-08-06 10:10:07.462902-04	\N
735ab415-1454-4104-8c9f-3a1b7fb077bf	d64a4899-20e4-4ecd-a53e-057aceed54cf	20dc13ff-1a11-4d00-85c2-40fbb8626333	ref=earnlayer123&utm_source=earnlayer	techcorp_affiliate	t	0.0250	USD	\N	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N
f505b2e4-b60c-4985-aec5-44269ced3f5a	d64a4899-20e4-4ecd-a53e-057aceed54cf	3fd615a3-4bcb-4c9a-825b-c74f02244bbd	aff=earnlayer456	bookstore_direct	t	0.0120	USD	\N	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N
c0d52474-2d52-4cf5-91da-827b1f7cdd57	d64a4899-20e4-4ecd-a53e-057aceed54cf	ed6822db-9052-4c76-8fd2-726115bd8c8a	sid=earnlayer	cj_affiliate	t	0.0500	USD	Commission Junction affiliate tracking	2025-08-06 15:25:49.153602-04	2025-08-06 15:25:49.153602-04	\N
3c96a281-9fc4-4ce9-8e72-53d8b18d6c53	d64a4899-20e4-4ecd-a53e-057aceed54cf	7b75b21e-9216-4903-ae81-33d28221f899	sid=earnlayer	cj_affiliate	t	0.0500	USD	Commission Junction affiliate tracking	2025-08-06 15:25:53.289898-04	2025-08-06 15:25:53.289898-04	\N
a1bf6eb0-e318-491f-9d8e-3ab237e0637a	d64a4899-20e4-4ecd-a53e-057aceed54cf	f1448859-c289-4faa-929e-595f1da1d564	sid=earnlayer	cj_affiliate	t	0.0500	USD	Commission Junction affiliate tracking	2025-08-06 15:25:57.256362-04	2025-08-06 15:25:57.256362-04	\N
ce4f51d4-101c-4dec-9fd9-77a478bcfaa6	d64a4899-20e4-4ecd-a53e-057aceed54cf	afca040b-e824-40cb-94ba-2f87bf9d990d	via=earnlayer	instantly_direct	t	0.0500	USD	\N	2025-08-06 17:11:28.92167-04	2025-08-06 17:11:28.92167-04	\N
6ffa61b4-5428-4b32-b32d-8436c5326a87	d64a4899-20e4-4ecd-a53e-057aceed54cf	30ef66aa-1fdd-4fb3-8e58-478244d492dc	subId1=earnlayer	shopify_direct	t	0.0300	USD	\N	2025-08-06 17:11:44.888149-04	2025-08-06 17:11:44.888149-04	\N
\.


--
-- Data for Name: creator_campaign_cpc_rates; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.creator_campaign_cpc_rates (id, creator_id, campaign_id, created_at, updated_at, cpc_rate_amount, currency, placement, ad_type) FROM stdin;
9d7e505c-7d21-45bb-b04c-fda76ffb80d5	d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	2025-07-19 08:31:36.301413-04	2025-07-19 08:31:36.301413-04	2.812500	USD	chat_inline	text
85056c90-5231-439b-9912-151234073a53	d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	0.150000	USD	chat_inline	text
b3334d71-078b-43d2-84c0-ca7a4dd62e25	d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	0.080000	USD	chat_inline	text
0fed2460-d6fd-4c0b-b43b-02c1273f3949	d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	0.100000	USD	chat_inline	text
\.


--
-- Data for Name: creator_category_preferences; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.creator_category_preferences (id, creator_id, category_id, created_at, updated_at, status) FROM stdin;
\.


--
-- Data for Name: creator_settings; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.creator_settings (id, creator_id, default_cpc, created_at, updated_at, deleted_at, default_category_pref) FROM stdin;
a18c9d71-fe30-4a45-b0e5-618f64c564e1	d64a4899-20e4-4ecd-a53e-057aceed54cf	1.000000	2025-06-22 12:24:06.470491-04	2025-06-22 12:24:06.470491-04	\N	inherit
27088642-708c-4b98-98f4-e7bd8127dfe7	52851592-e8fb-4a4b-b6b3-acc1b9962dc6	1.000000	2025-06-22 12:24:06.470491-04	2025-06-22 12:24:06.470491-04	\N	inherit
\.


--
-- Data for Name: creators; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.creators (id, user_id, name, bio, is_active, created_at, updated_at) FROM stdin;
d64a4899-20e4-4ecd-a53e-057aceed54cf	ab4acdbb-298d-4780-8029-e79f05f1c23d	EarnLayer Newsletter	\N	t	2025-06-21 20:45:45.386691-04	2025-06-21 20:45:45.386691-04
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	0963ca49-131e-45ec-843e-68970e5cd962	SuperHuman AI	\N	t	2025-06-21 20:45:45.395345-04	2025-06-21 20:45:45.395345-04
32872c3f-b91d-4897-bd2b-b79286e6b97c	41bbb10e-1399-4fc5-9825-e9c9101e30ff	Test Creator	Test bio	t	2025-07-13 21:45:57.880975-04	2025-07-13 21:45:57.880975-04
\.


--
-- Data for Name: default_ad_relationship; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.default_ad_relationship (id, creator_id, ad_id, ad_type, placement, is_global_default, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: effective_cpc_rates; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.effective_cpc_rates (creator_id, campaign_id, placement, ad_type, effective_cpc_rate) FROM stdin;
d64a4899-20e4-4ecd-a53e-057aceed54cf	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	content_promo	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	sidebar	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	chat_inline	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	sidebar	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	chat_inline	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	content_promo	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	sidebar	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	chat_inline	video	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	chat_inline	text	0.200000
d64a4899-20e4-4ecd-a53e-057aceed54cf	e6cb7d7e-3b67-42be-8849-d16f6c135844	content_promo	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	e6cb7d7e-3b67-42be-8849-d16f6c135844	sidebar	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	e6cb7d7e-3b67-42be-8849-d16f6c135844	chat_inline	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	e6cb7d7e-3b67-42be-8849-d16f6c135844	sidebar	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	e6cb7d7e-3b67-42be-8849-d16f6c135844	chat_inline	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	e6cb7d7e-3b67-42be-8849-d16f6c135844	content_promo	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	e6cb7d7e-3b67-42be-8849-d16f6c135844	sidebar	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	e6cb7d7e-3b67-42be-8849-d16f6c135844	chat_inline	video	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	e6cb7d7e-3b67-42be-8849-d16f6c135844	chat_inline	text	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	content_promo	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	sidebar	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	chat_inline	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	sidebar	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	chat_inline	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	content_promo	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	sidebar	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	chat_inline	video	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f735a55b-288e-4c4f-b49a-deed34f92f2c	chat_inline	text	2.812500
d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	content_promo	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	sidebar	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	chat_inline	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	sidebar	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	chat_inline	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	content_promo	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	sidebar	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	chat_inline	video	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a2d44548-c7d3-4b13-81a0-91abe15878bd	chat_inline	text	0.100000
d64a4899-20e4-4ecd-a53e-057aceed54cf	273d4140-65cd-42d5-955b-8f974ecac053	content_promo	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	273d4140-65cd-42d5-955b-8f974ecac053	sidebar	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	273d4140-65cd-42d5-955b-8f974ecac053	chat_inline	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	273d4140-65cd-42d5-955b-8f974ecac053	sidebar	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	273d4140-65cd-42d5-955b-8f974ecac053	chat_inline	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	273d4140-65cd-42d5-955b-8f974ecac053	content_promo	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	273d4140-65cd-42d5-955b-8f974ecac053	sidebar	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	273d4140-65cd-42d5-955b-8f974ecac053	chat_inline	video	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	273d4140-65cd-42d5-955b-8f974ecac053	chat_inline	text	0.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	8f170d7b-17ab-4245-8e99-8e010e335384	content_promo	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	8f170d7b-17ab-4245-8e99-8e010e335384	sidebar	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	8f170d7b-17ab-4245-8e99-8e010e335384	chat_inline	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	8f170d7b-17ab-4245-8e99-8e010e335384	sidebar	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	8f170d7b-17ab-4245-8e99-8e010e335384	chat_inline	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	8f170d7b-17ab-4245-8e99-8e010e335384	content_promo	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	8f170d7b-17ab-4245-8e99-8e010e335384	sidebar	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	8f170d7b-17ab-4245-8e99-8e010e335384	chat_inline	video	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	8f170d7b-17ab-4245-8e99-8e010e335384	chat_inline	text	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a0cb719f-486d-4c6a-a981-b4a52b8f805e	content_promo	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a0cb719f-486d-4c6a-a981-b4a52b8f805e	sidebar	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a0cb719f-486d-4c6a-a981-b4a52b8f805e	chat_inline	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a0cb719f-486d-4c6a-a981-b4a52b8f805e	sidebar	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a0cb719f-486d-4c6a-a981-b4a52b8f805e	chat_inline	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a0cb719f-486d-4c6a-a981-b4a52b8f805e	content_promo	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a0cb719f-486d-4c6a-a981-b4a52b8f805e	sidebar	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a0cb719f-486d-4c6a-a981-b4a52b8f805e	chat_inline	video	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a0cb719f-486d-4c6a-a981-b4a52b8f805e	chat_inline	text	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	content_promo	popup	0.012000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	sidebar	popup	0.012000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	chat_inline	popup	0.012000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	sidebar	hyperlink	0.012000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	chat_inline	hyperlink	0.012000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	content_promo	banner	0.012000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	sidebar	banner	0.012000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	chat_inline	video	0.012000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a5557f22-1736-4784-93e7-0a0ab5dc0adc	chat_inline	text	0.012000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a9202906-7dfa-4b7c-8cad-dc47b20f6106	content_promo	popup	0.030000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a9202906-7dfa-4b7c-8cad-dc47b20f6106	sidebar	popup	0.030000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a9202906-7dfa-4b7c-8cad-dc47b20f6106	chat_inline	popup	0.030000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a9202906-7dfa-4b7c-8cad-dc47b20f6106	sidebar	hyperlink	0.030000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a9202906-7dfa-4b7c-8cad-dc47b20f6106	chat_inline	hyperlink	0.030000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a9202906-7dfa-4b7c-8cad-dc47b20f6106	content_promo	banner	0.030000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a9202906-7dfa-4b7c-8cad-dc47b20f6106	sidebar	banner	0.030000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a9202906-7dfa-4b7c-8cad-dc47b20f6106	chat_inline	video	0.030000
d64a4899-20e4-4ecd-a53e-057aceed54cf	a9202906-7dfa-4b7c-8cad-dc47b20f6106	chat_inline	text	0.030000
d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	content_promo	popup	0.025000
d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	sidebar	popup	0.025000
d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	chat_inline	popup	0.025000
d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	sidebar	hyperlink	0.025000
d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	chat_inline	hyperlink	0.025000
d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	content_promo	banner	0.025000
d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	sidebar	banner	0.025000
d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	chat_inline	video	0.025000
d64a4899-20e4-4ecd-a53e-057aceed54cf	95df4760-66b1-4d0a-9265-a9cbdc275a56	chat_inline	text	0.025000
d64a4899-20e4-4ecd-a53e-057aceed54cf	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	content_promo	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	sidebar	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	chat_inline	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	sidebar	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	chat_inline	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	content_promo	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	sidebar	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	chat_inline	video	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	chat_inline	text	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	5daa5906-1ba6-4831-9fba-320eec7b910c	content_promo	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	5daa5906-1ba6-4831-9fba-320eec7b910c	sidebar	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	5daa5906-1ba6-4831-9fba-320eec7b910c	chat_inline	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	5daa5906-1ba6-4831-9fba-320eec7b910c	sidebar	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	5daa5906-1ba6-4831-9fba-320eec7b910c	chat_inline	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	5daa5906-1ba6-4831-9fba-320eec7b910c	content_promo	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	5daa5906-1ba6-4831-9fba-320eec7b910c	sidebar	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	5daa5906-1ba6-4831-9fba-320eec7b910c	chat_inline	video	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	5daa5906-1ba6-4831-9fba-320eec7b910c	chat_inline	text	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f46fce08-791e-46ed-94d4-6baba2bfb9ea	content_promo	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f46fce08-791e-46ed-94d4-6baba2bfb9ea	sidebar	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f46fce08-791e-46ed-94d4-6baba2bfb9ea	chat_inline	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f46fce08-791e-46ed-94d4-6baba2bfb9ea	sidebar	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f46fce08-791e-46ed-94d4-6baba2bfb9ea	chat_inline	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f46fce08-791e-46ed-94d4-6baba2bfb9ea	content_promo	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f46fce08-791e-46ed-94d4-6baba2bfb9ea	sidebar	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f46fce08-791e-46ed-94d4-6baba2bfb9ea	chat_inline	video	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	f46fce08-791e-46ed-94d4-6baba2bfb9ea	chat_inline	text	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	eae4c673-093e-40ba-8750-1866791716a0	content_promo	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	eae4c673-093e-40ba-8750-1866791716a0	sidebar	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	eae4c673-093e-40ba-8750-1866791716a0	chat_inline	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	eae4c673-093e-40ba-8750-1866791716a0	sidebar	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	eae4c673-093e-40ba-8750-1866791716a0	chat_inline	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	eae4c673-093e-40ba-8750-1866791716a0	content_promo	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	eae4c673-093e-40ba-8750-1866791716a0	sidebar	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	eae4c673-093e-40ba-8750-1866791716a0	chat_inline	video	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	eae4c673-093e-40ba-8750-1866791716a0	chat_inline	text	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	cb0c2f3b-913f-49a8-8560-2e5780551850	content_promo	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	cb0c2f3b-913f-49a8-8560-2e5780551850	sidebar	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	cb0c2f3b-913f-49a8-8560-2e5780551850	chat_inline	popup	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	cb0c2f3b-913f-49a8-8560-2e5780551850	sidebar	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	cb0c2f3b-913f-49a8-8560-2e5780551850	chat_inline	hyperlink	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	cb0c2f3b-913f-49a8-8560-2e5780551850	content_promo	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	cb0c2f3b-913f-49a8-8560-2e5780551850	sidebar	banner	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	cb0c2f3b-913f-49a8-8560-2e5780551850	chat_inline	video	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	cb0c2f3b-913f-49a8-8560-2e5780551850	chat_inline	text	0.050000
d64a4899-20e4-4ecd-a53e-057aceed54cf	406ef64f-f508-4764-a8e3-94e92abe3c0a	content_promo	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	406ef64f-f508-4764-a8e3-94e92abe3c0a	sidebar	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	406ef64f-f508-4764-a8e3-94e92abe3c0a	chat_inline	popup	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	406ef64f-f508-4764-a8e3-94e92abe3c0a	sidebar	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	406ef64f-f508-4764-a8e3-94e92abe3c0a	chat_inline	hyperlink	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	406ef64f-f508-4764-a8e3-94e92abe3c0a	content_promo	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	406ef64f-f508-4764-a8e3-94e92abe3c0a	sidebar	banner	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	406ef64f-f508-4764-a8e3-94e92abe3c0a	chat_inline	video	1.000000
d64a4899-20e4-4ecd-a53e-057aceed54cf	406ef64f-f508-4764-a8e3-94e92abe3c0a	chat_inline	text	15.250000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f735a55b-288e-4c4f-b49a-deed34f92f2c	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f735a55b-288e-4c4f-b49a-deed34f92f2c	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f735a55b-288e-4c4f-b49a-deed34f92f2c	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f735a55b-288e-4c4f-b49a-deed34f92f2c	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f735a55b-288e-4c4f-b49a-deed34f92f2c	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f735a55b-288e-4c4f-b49a-deed34f92f2c	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f735a55b-288e-4c4f-b49a-deed34f92f2c	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f735a55b-288e-4c4f-b49a-deed34f92f2c	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f735a55b-288e-4c4f-b49a-deed34f92f2c	chat_inline	text	0.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a2d44548-c7d3-4b13-81a0-91abe15878bd	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a2d44548-c7d3-4b13-81a0-91abe15878bd	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a2d44548-c7d3-4b13-81a0-91abe15878bd	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a2d44548-c7d3-4b13-81a0-91abe15878bd	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a2d44548-c7d3-4b13-81a0-91abe15878bd	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a2d44548-c7d3-4b13-81a0-91abe15878bd	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a2d44548-c7d3-4b13-81a0-91abe15878bd	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a2d44548-c7d3-4b13-81a0-91abe15878bd	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a2d44548-c7d3-4b13-81a0-91abe15878bd	chat_inline	text	0.100000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e6cb7d7e-3b67-42be-8849-d16f6c135844	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e6cb7d7e-3b67-42be-8849-d16f6c135844	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e6cb7d7e-3b67-42be-8849-d16f6c135844	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e6cb7d7e-3b67-42be-8849-d16f6c135844	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e6cb7d7e-3b67-42be-8849-d16f6c135844	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e6cb7d7e-3b67-42be-8849-d16f6c135844	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e6cb7d7e-3b67-42be-8849-d16f6c135844	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e6cb7d7e-3b67-42be-8849-d16f6c135844	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	e6cb7d7e-3b67-42be-8849-d16f6c135844	chat_inline	text	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	983cd0ff-83b5-4c9f-ae14-96d8296eb30c	chat_inline	text	0.200000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5557f22-1736-4784-93e7-0a0ab5dc0adc	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5557f22-1736-4784-93e7-0a0ab5dc0adc	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5557f22-1736-4784-93e7-0a0ab5dc0adc	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5557f22-1736-4784-93e7-0a0ab5dc0adc	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5557f22-1736-4784-93e7-0a0ab5dc0adc	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5557f22-1736-4784-93e7-0a0ab5dc0adc	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5557f22-1736-4784-93e7-0a0ab5dc0adc	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5557f22-1736-4784-93e7-0a0ab5dc0adc	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a5557f22-1736-4784-93e7-0a0ab5dc0adc	chat_inline	text	0.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	8f170d7b-17ab-4245-8e99-8e010e335384	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	8f170d7b-17ab-4245-8e99-8e010e335384	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	8f170d7b-17ab-4245-8e99-8e010e335384	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	8f170d7b-17ab-4245-8e99-8e010e335384	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	8f170d7b-17ab-4245-8e99-8e010e335384	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	8f170d7b-17ab-4245-8e99-8e010e335384	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	8f170d7b-17ab-4245-8e99-8e010e335384	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	8f170d7b-17ab-4245-8e99-8e010e335384	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	8f170d7b-17ab-4245-8e99-8e010e335384	chat_inline	text	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	273d4140-65cd-42d5-955b-8f974ecac053	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	273d4140-65cd-42d5-955b-8f974ecac053	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	273d4140-65cd-42d5-955b-8f974ecac053	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	273d4140-65cd-42d5-955b-8f974ecac053	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	273d4140-65cd-42d5-955b-8f974ecac053	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	273d4140-65cd-42d5-955b-8f974ecac053	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	273d4140-65cd-42d5-955b-8f974ecac053	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	273d4140-65cd-42d5-955b-8f974ecac053	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	273d4140-65cd-42d5-955b-8f974ecac053	chat_inline	text	0.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a0cb719f-486d-4c6a-a981-b4a52b8f805e	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a0cb719f-486d-4c6a-a981-b4a52b8f805e	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a0cb719f-486d-4c6a-a981-b4a52b8f805e	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a0cb719f-486d-4c6a-a981-b4a52b8f805e	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a0cb719f-486d-4c6a-a981-b4a52b8f805e	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a0cb719f-486d-4c6a-a981-b4a52b8f805e	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a0cb719f-486d-4c6a-a981-b4a52b8f805e	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a0cb719f-486d-4c6a-a981-b4a52b8f805e	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a0cb719f-486d-4c6a-a981-b4a52b8f805e	chat_inline	text	0.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a9202906-7dfa-4b7c-8cad-dc47b20f6106	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a9202906-7dfa-4b7c-8cad-dc47b20f6106	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a9202906-7dfa-4b7c-8cad-dc47b20f6106	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a9202906-7dfa-4b7c-8cad-dc47b20f6106	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a9202906-7dfa-4b7c-8cad-dc47b20f6106	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a9202906-7dfa-4b7c-8cad-dc47b20f6106	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a9202906-7dfa-4b7c-8cad-dc47b20f6106	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a9202906-7dfa-4b7c-8cad-dc47b20f6106	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	a9202906-7dfa-4b7c-8cad-dc47b20f6106	chat_inline	text	0.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	cb0c2f3b-913f-49a8-8560-2e5780551850	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	cb0c2f3b-913f-49a8-8560-2e5780551850	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	cb0c2f3b-913f-49a8-8560-2e5780551850	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	cb0c2f3b-913f-49a8-8560-2e5780551850	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	cb0c2f3b-913f-49a8-8560-2e5780551850	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	cb0c2f3b-913f-49a8-8560-2e5780551850	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	cb0c2f3b-913f-49a8-8560-2e5780551850	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	cb0c2f3b-913f-49a8-8560-2e5780551850	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	cb0c2f3b-913f-49a8-8560-2e5780551850	chat_inline	text	0.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	c8eabc10-a90d-439c-9e58-fd9582c0e7f3	chat_inline	text	0.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	5daa5906-1ba6-4831-9fba-320eec7b910c	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	5daa5906-1ba6-4831-9fba-320eec7b910c	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	5daa5906-1ba6-4831-9fba-320eec7b910c	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	5daa5906-1ba6-4831-9fba-320eec7b910c	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	5daa5906-1ba6-4831-9fba-320eec7b910c	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	5daa5906-1ba6-4831-9fba-320eec7b910c	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	5daa5906-1ba6-4831-9fba-320eec7b910c	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	5daa5906-1ba6-4831-9fba-320eec7b910c	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	5daa5906-1ba6-4831-9fba-320eec7b910c	chat_inline	text	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f46fce08-791e-46ed-94d4-6baba2bfb9ea	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f46fce08-791e-46ed-94d4-6baba2bfb9ea	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f46fce08-791e-46ed-94d4-6baba2bfb9ea	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f46fce08-791e-46ed-94d4-6baba2bfb9ea	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f46fce08-791e-46ed-94d4-6baba2bfb9ea	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f46fce08-791e-46ed-94d4-6baba2bfb9ea	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f46fce08-791e-46ed-94d4-6baba2bfb9ea	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f46fce08-791e-46ed-94d4-6baba2bfb9ea	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	f46fce08-791e-46ed-94d4-6baba2bfb9ea	chat_inline	text	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	eae4c673-093e-40ba-8750-1866791716a0	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	eae4c673-093e-40ba-8750-1866791716a0	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	eae4c673-093e-40ba-8750-1866791716a0	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	eae4c673-093e-40ba-8750-1866791716a0	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	eae4c673-093e-40ba-8750-1866791716a0	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	eae4c673-093e-40ba-8750-1866791716a0	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	eae4c673-093e-40ba-8750-1866791716a0	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	eae4c673-093e-40ba-8750-1866791716a0	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	eae4c673-093e-40ba-8750-1866791716a0	chat_inline	text	0.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	406ef64f-f508-4764-a8e3-94e92abe3c0a	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	406ef64f-f508-4764-a8e3-94e92abe3c0a	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	406ef64f-f508-4764-a8e3-94e92abe3c0a	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	406ef64f-f508-4764-a8e3-94e92abe3c0a	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	406ef64f-f508-4764-a8e3-94e92abe3c0a	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	406ef64f-f508-4764-a8e3-94e92abe3c0a	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	406ef64f-f508-4764-a8e3-94e92abe3c0a	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	406ef64f-f508-4764-a8e3-94e92abe3c0a	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	406ef64f-f508-4764-a8e3-94e92abe3c0a	chat_inline	text	15.250000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	95df4760-66b1-4d0a-9265-a9cbdc275a56	content_promo	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	95df4760-66b1-4d0a-9265-a9cbdc275a56	sidebar	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	95df4760-66b1-4d0a-9265-a9cbdc275a56	chat_inline	popup	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	95df4760-66b1-4d0a-9265-a9cbdc275a56	sidebar	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	95df4760-66b1-4d0a-9265-a9cbdc275a56	chat_inline	hyperlink	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	95df4760-66b1-4d0a-9265-a9cbdc275a56	content_promo	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	95df4760-66b1-4d0a-9265-a9cbdc275a56	sidebar	banner	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	95df4760-66b1-4d0a-9265-a9cbdc275a56	chat_inline	video	1.000000
52851592-e8fb-4a4b-b6b3-acc1b9962dc6	95df4760-66b1-4d0a-9265-a9cbdc275a56	chat_inline	text	0.000000
\.


--
-- Data for Name: embeddings; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.embeddings (source_table, source_id, embedding, created_at, chunk_id) FROM stdin;
content	24416f45-db3c-4a52-9a74-ed863bb2eecd	[0.009263146,0.024898006,-0.012871771,0.021395072,0.044360425,-0.047893558,0.018103523,0.05046036,-0.014041932,0.0069718948,0.018299809,-0.04381687,-0.023161639,-0.052785587,-0.011150502,-0.0017090013,-0.059217695,-0.036478825,-0.028627422,-0.011716709,-0.008485555,0.01605008,-0.016246364,0.04623268,0.0073153935,0.001985499,-0.006209403,0.017846843,-0.005152483,-0.021093095,0.012969913,-0.029608848,-0.03312688,-0.018556489,0.0014947864,-0.0037879243,-0.011339238,0.016774824,0.00559035,0.0035520047,0.0004888253,-0.00025573678,0.045960903,-0.0037822623,-0.012147026,-0.00026517358,-0.010954217,-0.024339348,-0.01656344,0.039649583,-0.06057659,0.017106999,-0.037233766,0.021002503,-0.06800523,0.019688902,-0.025547257,-0.005771536,-0.0018250736,0.023342824,0.058432557,-0.008055237,0.037112977,0.018496092,-0.06371716,-0.008840377,-0.025124488,0.044632204,-0.008613895,0.00071719545,0.017288186,-0.019417124,-0.0128038265,0.00025762417,-0.027917776,-0.02852173,0.0005732845,0.08334566,1.3698079e-05,-0.02708734,0.021666853,0.0056054485,-0.02406757,-0.013883394,-0.019749297,-0.009814253,-0.009534924,-0.024399744,-0.073018044,-0.0031726463,-0.02418836,-0.02353911,-0.014102328,0.006092387,0.0011286391,0.056892473,0.0030990392,0.020096572,0.03222095,0.03774713,0.0077759083,-0.00358409,-0.021772543,0.008666741,0.004571177,-0.0028159358,0.013883394,0.027615799,0.0088932235,0.028053666,-0.10279298,-0.018480994,-0.028174456,0.020474043,-0.040827293,-0.03433479,0.009942594,0.025622752,0.0060168924,-0.034093205,-0.035150126,0.029065289,0.024173262,-0.0029008668,0.019115146,-0.039196618,-0.0073984372,-0.048708893,-0.045145568,-0.06927353,-0.0019279346,0.018209215,0.038230292,-0.039770376,-0.0076211453,-0.04405845,0.0029235152,-0.013075605,-0.033579845,-0.0061225845,0.004499458,-0.03877385,-0.03364024,0.009421683,-0.05284598,-0.025033895,-0.004435288,-0.03379123,-0.015023357,-0.0056771683,-0.02181784,0.0026592852,-0.01932653,0.010508801,0.0068435543,-0.009278244,0.004707067,0.063656755,-0.010871173,-0.047893558,-0.020353252,0.03995156,-0.015091302,-0.0018892438,-0.038471874,0.020187164,-0.0036897818,-0.021983927,-0.087150574,-0.042005006,0.004729715,-0.033217475,0.008327017,0.0029084163,0.00031353708,-0.0040842392,0.0151064005,0.025003698,-0.038320884,-0.032673914,-0.053389538,-0.022029225,-0.02905019,0.0021893336,-0.018511191,-0.023478715,-0.02722323,-0.0006204684,-0.053661317,0.0076664416,-0.0012683035,0.03430459,0.056077134,0.04653466,0.025607653,-0.011520424,0.053147957,-0.026136111,0.015974585,-0.03394222,0.051215306,0.030258099,0.0038086853,-0.012063982,0.035180323,-0.016940912,0.068427995,0.019779496,-0.036327835,0.030786559,0.07760809,-0.044873785,0.011746907,0.036056057,-0.06335478,-0.037958514,-0.030273197,-0.019447321,0.0033557198,0.06697851,-0.045447543,0.039921362,0.029820232,0.006450984,-0.017363679,0.0008356271,0.02826505,-0.00065444084,0.031254623,-0.0012060207,0.016352056,-0.0005251569,-0.03768673,-0.040283736,0.033730835,-0.035935268,0.045205962,-0.033851624,0.01697111,-0.03342886,0.0060131177,-0.0018665955,0.026996747,0.011777104,-0.027449712,0.030801658,-0.012909518,-0.034093205,0.021334678,0.011603467,0.06142213,-0.020292856,0.022950254,0.018330006,0.038592663,-0.048950475,-0.02352401,0.01734858,-0.0025554807,-0.0064207865,-0.008561049,0.015287587,-0.04653466,0.006413237,0.035844672,0.02011167,-0.0015816047,0.027812084,-0.009376387,-0.032915495,-0.0068133567,0.0062320507,0.017801546,0.0018524403,-0.03312688,-0.023674998,-0.003284,-0.029699441,-0.0004874098,0.054114282,0.0032915496,-0.0038690807,0.039619386,-0.014162723,-0.0032594646,-0.010048286,-0.028431138,-0.018631984,-0.06891116,-0.027993271,0.024278954,-0.027404416,0.001657099,-0.023191836,-0.016216166,-0.018601784,0.025426466,0.034093205,-0.017529767,-0.006907725,0.042005006,-0.07386358,0.010546547,-0.009142354,0.0027819634,0.08068826,-0.06377755,-0.014041932,0.0157783,-0.042125795,-0.031345215,0.036358036,0.041068874,-0.058885522,-0.061844897,-0.008047688,0.055654366,-0.036388233,0.017922336,-0.026468286,-0.016940912,0.009172552,-0.008870576,0.018118622,-0.0631132,-0.03955899,0.018511191,-0.014517546,-0.008100534,-0.055141006,0.027555404,0.023388121,-0.017182494,-0.005088313,0.0011305265,-0.04348469,-0.018496092,-0.023554208,0.019084949,-0.056469705,-0.06558941,-0.009059311,-0.03653922,0.00010663564,0.015748102,-0.007345591,-0.0016552116,-0.004854281,0.022436893,0.035723884,-0.013641812,-0.016895615,0.008500653,-0.009406584,-0.024913104,0.043424297,-0.0017099449,-0.009814253,-0.004337145,-0.011694061,-0.048829686,0.013219045,0.0420654,0.01564241,0.020338153,0.006164106,-0.04587031,0.03012221,0.02299555,-0.0047108415,0.010297417,-0.011648764,0.014094777,-0.0058470303,-0.041219864,-0.05139649,-0.00017564211,-0.006031991,0.008523301,0.031979367,-0.009919945,-0.00048788163,-0.0131133525,-0.028461335,-0.026347496,-0.012977463,0.00047679342,-0.025154687,-0.08026549,-0.013302088,0.024520535,-0.02775169,-0.04689703,0.012917068,0.018254511,0.03907583,0.022965353,0.023644801,0.051607873,0.06613297,0.013649362,-0.019100048,-2.7057024e-06,0.0061603314,-0.016231265,-0.01157327,0.01746937,0.02867272,-0.00945943,0.012947265,0.0630528,-0.037958514,0.040313933,-0.003049968,-0.038139697,0.010237021,0.007843853,0.026136111,0.0073682396,0.08497634,0.020187164,-0.060002837,-0.0049750716,-0.037414953,-0.03493874,0.017831743,0.021485666,-0.025954926,0.017695853,-0.051245503,-0.04571932,0.013158649,0.053540528,-0.042820342,0.013898493,0.006666143,0.030439284,0.02459603,0.028687818,0.008145831,0.022044323,-0.002583791,-0.049010873,-0.039860968,-0.036146652,-0.0073418166,-0.07054184,0.009225398,-0.05061135,-0.074105166,-0.039257012,-0.002795175,0.03427439,0.018088425,-0.040464923,-0.046081696,0.06269043,-0.041642632,-0.011694061,0.031133832,0.013777702,-0.008772433,-0.017695853,0.016155772,0.02444504,0.034213997,-0.01617087,0.018450797,0.017106999,-0.0027838508,0.0005322345,0.0048807035,-0.039649583,-0.019854989,-0.019160442,-0.021485666,0.00999544,-0.0170919,-0.007390888,0.00802504,-0.00015275792,-0.004272975,-0.008478005,0.015717905,-0.0061716554,-0.016336957,-0.017831743,-0.03270411,0.0134757245,0.010659789,-0.006794483,-0.0078816,0.071025,-0.018586686,0.039860968,-0.0073078442,-0.021712149,-0.014509996,-0.010750382,-0.0131661985,0.011867697,-0.02747991,-0.04756138,0.01801293,0.0034916094,0.007273872,0.03877385,0.033972416,-0.032553125,0.036961988,0.013679559,0.025683146,0.0037350785,0.05574496,-0.004586276,0.030258099,0.008621444,0.07899719,0.009036663,0.008923422,0.0029669243,0.016518144,0.01301521,-0.00762492,-0.013000111,-0.015370631,-0.053027168,-0.030862052,-0.021470567,-0.018571587,0.0073342673,0.0011522311,0.0011833725,-0.007322943,-0.06891116,-0.02485271,-0.009844451,-0.01235841,-0.046202485,0.027072242,0.0183904,0.022225508,0.014623238,0.019900287,-0.010289867,-0.020292856,-0.0134757245,-0.025743542,-0.008440258,0.028370742,0.0907743,-0.0068662027,0.017529767,-0.0059715956,0.009232948,0.023916582,0.020957205,0.0067793843,0.0065264786,-0.0029669243,0.0028046116,-0.014925214,-0.0027630897,0.02181784,-0.011618566,0.008681839,0.022195311,0.014041932,-0.010131329,0.019024553,-0.027827183,-0.031918973,0.01775625,-0.011361886,0.022119818,0.013687109,0.04324311,0.009180102,0.005639421,0.0552618,-0.026453188,-0.0139437895,-0.0038955037,0.023946779,-0.037626337,0.030409086,-0.023508912,0.01459304,0.0069567957,0.025607653,0.048678696,-0.018465895,-0.026241804,0.0047636875,0.0052544004,-0.0064623086,0.032945693,-0.023237132,-0.008787531,0.031767983,-0.004767462,-0.0074777063,-0.027555404,-0.0020760922,-0.037414953,-0.02038345,0.010735284,-0.007311619,0.02432425,-0.00067001156,-0.008976268,0.023901481,-0.007466382,-0.026166309,-0.028098963,0.008047688,0.0066359453,0.008598796,0.065770596,-0.010954217,-0.04300153,-0.020398548,-0.01932653,-0.007534327,0.015030907,0.010365361,0.0048958026,-0.035844672,-0.018299809,-0.013158649,0.010893822,0.024475237,0.035150126,0.012373509,0.00854595,-0.04638367,-0.013770153,0.013838097,0.05009799,-0.02930687,0.011527973,0.013188846,0.011656313,-0.031466007,-0.010833426,-0.016321858,-0.02575864,-0.03364024,-0.020187164,0.007904248,-0.01564241,-0.036478825,0.03089225,0.027117537,0.023478715,-0.003903053,-0.02183294,-0.0030480807,0.007715513,0.007949545,-0.02128938,-0.0013919254,-0.035935268,-0.020685427,-0.0131511,0.0044503864,0.0140192835,0.027359119,-0.009097058,-0.007466382,-0.039106026,0.007194603,0.030061813,0.029790035,-0.010924019,-0.0013117127,0.009625518,-0.03493874,0.0486485,-0.01721269,0.0137097575,0.010372911,-0.06341518,0.003659584,0.034485776,-0.0026536232,0.017001307,0.0116638625,0.014479798,-0.016744627,-0.009361288,-0.00063084887,0.0022686024,-0.025260378,-0.006824681,-0.010471053,0.0039936462,0.025471762,-0.027615799,-0.13117883,-0.016487947,0.048678696,-0.014034382,-0.033851624,0.010327615,-0.0355125,-0.014706281,0.022285905,0.06993788,0.013755053,-0.03798871,-0.036750603,-0.012962364,-0.0049109017,0.003906828,-0.019507715,0.03367044,0.014124976,-0.0049335496,-0.012381058,-0.020851513,-0.012290465,-0.0076739914,0.00045886353,0.00933109,-0.0394382,-0.013490824,0.022044323,-0.045779716,0.03521052,0.008591247,-0.03179818,0.010569196,-0.047651976,-0.017514668,0.015385729,-0.027238328,-0.0029612621,-0.025033895,-0.013302088,-0.01340778,-0.0035293566,0.033700638,0.048588105,-0.04532675,-0.0061188093,0.028944498,0.02879351,-0.0005501644,-0.02091191,0.022889858,0.016080277,-0.03983077,0.005616773,0.008900773,-0.008145831,-0.02142527,-0.018586686,-0.008342115,0.011739357,0.043273307,0.044330228,-0.0029725863,0.03116403,0.0019628508,-0.0083496645,0.017122097,0.022376498,-0.025033895,0.015453675,0.007141757,0.010674888,-0.0081684785,-0.019960681,0.014532644,0.0017637346,0.005492207,-0.006386814,0.015174346,-0.0106295915,0.008493104,0.015989684,-0.019492617,0.019960681,-0.0012975575,-0.0552014,-0.0015853794,-0.012781178,-0.022844562,-0.0055828,-0.028506631,-0.020202264,-0.011762005,-0.0033274095,-0.01012378,0.042699553,0.011928093,-0.109315686,0.03062047,0.040162943,-0.007270097,0.0047410396,0.0016552116,0.010191725,0.025320774,0.0069379224,-0.0035633289,0.023946779,-0.033398658,-0.030952645,-0.0065830993,0.021772543,-0.013256792,-0.014683633,-0.01090892,-0.017499568,-0.022572784,-0.029608848,-0.00081486616,0.013883394,0.020791119,-0.025834136,-0.046685647,0.0003800664,0.024958402,-0.0005341219,-0.009806704,-0.029125685,0.001601422,-0.030152407,0.021515863,-0.02865762,0.025064094,-0.012690585,0.0043409197,0.0020760922,-0.0015268713,-0.00039752445,-0.0042276783,0.03460657,-0.028853904,-0.022240609,0.012275366,0.045598533,-0.009346189,0.020609932,0.020036176,0.0068284557,-0.000560073,-0.0065642255,-0.011935642,-0.044360425,-0.004982621,-0.02772149,-0.009157454,0.04747079,0.025411367,-0.002970699,0.0015731116,0.016744627,-0.01721269,-0.00768909,-0.004722166,0.0021195014,0.024278954,0.00081958453,-0.012562244,0.0010201161,0.021757444,0.021334678,0.033730835,0.010848525,-0.038592663,0.025064094,0.029533353,0.00058460864,-0.030741261,0.0670389,-0.045024775,-0.010961766,0.006126359,-0.03049968,0.04381687,-0.021485666,0.011837499,0.010304966,0.0067756097,0.02444504,-0.025215082,0.0077457107,-0.016442649,0.00033500578,-0.006228276,-0.021485666,0.007851403,0.026256902,0.0021213887,0.064985454,0.008659191,-0.0033745933,0.015325334,-0.036871396,-0.0035293566,0.002208207,-0.025909629,0.018224314,0.0069567957,-0.021742346,-0.001355122,0.0013541783,0.036448628,-0.011973389,0.021183688,0.011271292,-0.021259183,-0.003914377,-0.014962962,0.03901543,-0.014321261,-0.03342886,-0.016382255,-0.015083753,-0.006243375,0.0014749691,-0.0045296554,-0.005813058,-0.015868893,-0.011490226,0.012177223,0.0009290512,0.014449601,0.008402511,0.0004527296,0.0025328323,0.012773628,-0.017439174,0.019568112,-0.0020081473,0.00033618536,-0.007806106,-0.007843853,0.02563785,-0.030167505,-0.012766079,0.028597225,-0.006466083,0.029231377,0.0092555955,-0.010455955,-0.013747504,0.031828377,-0.007273872,0.0041635083,-0.009950143,-0.031888776,-0.02142527,0.006594423,0.040555514,0.020881712,0.00042088047,0.021304479,0.0021157265,-0.035421904,-0.0012248943,-0.005178906,0.006326419,0.021349777,-0.009421683,0.017816644,0.0446624,0.034153603,0.03602586,0.03484815,0.021651752,0.018375302,0.026800461,0.008379863,-0.016457748,0.041642632,-0.0029952347,0.04638367,0.0074512833,-0.015370631,0.0089460695,0.019356728,0.008651642,0.00025974744,0.010131329,-0.01301521,0.010848525,0.023131441,-0.0073040696,-0.007730612,0.010320065,0.013437978,-0.012086631,-0.00023367832,0.0052393014,0.013739955,-0.0074324096,-0.017439174,-0.010342713,0.005597899,-0.0020213588,-0.009942594,-0.00841006,-0.006873752,-0.022451991,-0.017529767,-0.014698732,0.003568991,-0.008327017,0.0006903006,-0.0024384644,0.037233766,-0.032009564,-0.033821426,-0.012124377,-0.0017071139,-0.046776243,-0.0038030231,-0.0017137197,0.0060395407,0.019598309,-0.010463504,0.018813169,0.007051164,0.026121013,0.013400231,0.006228276,0.018737674,0.016397353,-0.012773628,-0.00709646,0.0016523806,0.010614493,0.03708278,-0.00800994,0.018179018,-0.012071532,-0.013951339,0.0043673427,0.0114826765,0.0315264,0.022029225,-0.0036992186,0.013445527,0.009595321,0.019568112,0.03798871,0.022753969,0.007179504,-0.004578727,0.009693462,0.031405613,0.0010748495,-0.027706392,0.0013588966,0.013332286,-0.017393878,-0.00762492,-0.0012296127,-0.008840377,0.0047523635,0.00800994,0.02302575,0.03484815,-0.007356915,0.03720357,-0.012901968,0.0009111213,-0.0076588923,-0.0060244417,-0.052544,0.039377805,0.019507715,-0.011686511,-0.03128482,-0.010478603,-0.01987009,0.005205329,0.008077886,-0.0063943635,-0.02406757,-0.011392083,0.031375412,0.014766676,-0.0019741748,0.030680867,0.0018599897,0.016593637,-0.019794594,-0.004918451,-0.0056054485,-0.01601988,0.02548686,0.011203348,0.0044201887,0.041642632,-0.005665844,-0.02430915,0.037294164,-0.018284708,0.002795175,-0.055171203,0.03587487,0.021319577,-0.049645025,0.027585601,-0.0083496645,-0.0034783978,-0.0027932876,-0.012698134,-0.025547257,0.0044843587,0.0184055,-0.016744627,-0.0040993383,0.042910937,0.02681556,0.045205962,0.022029225,-0.0022063197,0.011731807,0.024127964,0.041642632,0.019477518,0.047289602,-0.01157327,0.012214971,0.019673804,-0.026860857,0.0038030231,-0.033459056,0.00364826,0.0057564373,-0.019432222,-0.041189667,0.004507007,0.0038728553,0.021591358,0.027555404,-0.011225996,-0.023010649,-0.0005912144,0.00756075,-0.005205329,0.09953163,-0.026951449,-0.011052359,0.0036048507,-0.0033066485,0.022195311,-0.0022384047,0.003574653,0.00096349546,-0.024294052,-0.043363903,-0.0060282163,0.021712149,0.02062503,0.0289143,-0.011512875,0.0022855885,-0.021123294,-0.0069341473,-0.0055941246,0.021334678,0.006443435,-0.0033840302,-0.022467092,0.02444504,0.0015372519,0.032130357,-0.032281343,0.037233766,-0.0018864127,0.020579735,-0.008047688,-0.004876929,0.030288296,0.014766676,0.0033292968,-0.01813372,-0.021198787,-0.013875845,-0.004590051,0.005024143,-0.0001399003,0.00014438276,-0.017182494,-0.0077457107,-0.005050566,0.0058168327,-0.0091952,-0.03717337,-0.033459056,-0.038230292,0.014245766,0.0052355267,0.009550024,-0.0043937657,-0.010803228,-0.016518144,0.06534783,0.0032368163,-0.0026328622,-0.044632204,0.02642299,-0.012426355,0.021802742,-0.04257876,-0.025879432,0.0019345403,0.013898493,-0.007466382,0.026241804,0.005284598,-0.0013522909,0.02287476,-0.0043975404,0.0052393014,0.02548686,-0.0018316794,0.017046602,0.035723884,0.019417124,-0.017590161,0.007836304,0.017650558,0.024354447,-0.021485666,-0.00022424154,0.019356728,0.004488134,-0.055533577,-0.014804424,-0.042669356,-0.0065529016,0.027691294,0.04131046,-0.008847927,0.0014381655,-0.030680867,0.016940912,-0.02524528,0.0052883727,-0.024414843,0.023674998,-0.018813169,-0.024127964,0.01078058,0.017106999,-0.04091789,0.016925812,0.017695853,0.0004005914,-0.024203459,0.017001307,0.022935156,0.008530851,-0.007439959,0.008636543,0.050550956,0.02418836,-0.010138879,-0.0722329,0.009512276,0.014351458,-0.0013485162,-0.02405247,-0.00400497,0.0045183315,0.016608737,-0.052242026,0.01064469,-0.018043127,-0.021515863,0.012154575,0.012516947,-0.022980452,-0.010289867,0.033821426,-0.009240497,-0.03185858,-0.013068056,-0.0037086555,-0.0040955637,0.020836415,0.0062848968,-0.012592442,0.017695853,-0.046987627,-0.010546547,-0.0017250438,-0.021410171,0.012811376,-0.004235228,-0.0059187496,0.020036176,0.017454272,-0.00026045518,-0.013717307,0.01722779,-0.030816756,-0.023946779,-0.0037464024,-0.0059904694,-0.015627312,-0.028567027,-0.018631984,0.0042012553,-0.006424561,-0.02510939,0.013158649,-0.00762492,-0.011059909,0.014057031,0.008659191,-0.03206996,0.014660985,0.0157783,-0.044088647,0.010667339,0.022436893,-0.028416038,0.028899202,-0.014532644,-0.0049335496,0.027298724,0.0003147167,-0.038320884,0.021259183,0.002213869,0.018586686,-0.054748435,-0.0089460695,-0.018526291,0.010153977,-0.025064094,0.006654819,0.021893336,0.037777327,-0.010984414,-0.0026139887,0.0047523635,0.011792203,-0.039287213,0.017952535,-0.026664572,-0.029925924,-0.02538117,0.034999136,0.010455955,-0.00768909,0.005412938,0.022225508,-0.020489141,0.011014612,-0.01078058,0.023222033,0.010554098,-0.032492727,0.0028725564,0.0289294,0.009051762,-0.016321858,0.0028291473,-0.0016316196,-0.010289867,-0.009942594,0.035331313,0.0060810624,0.03617685,-0.011233546,0.022708673,0.02643809,0.014570392,-0.0072889705,0.017167395,0.011014612,-0.016518144,-0.014660985,-0.0035142577,-0.004812759,0.038049106,0.0042503267,-0.019130245,0.016321858,-0.0037728255,0.02773659,-0.038139697,0.041974805,0.02800837,-0.0276007,-0.02942766,0.017424075,0.034787755,0.013626713,-0.0028895426,0.0013947564,0.008779982,-0.029880628,-0.007428635,-0.00022400562,0.001305107,0.014291063,-0.037414953,-0.018330006,0.01917554,-0.028869005,-0.036750603,0.021077996,-0.031979367,0.030575175,-0.0037237543,0.0009087621,-0.0030386439,-0.0016165208,0.0038483199,0.00249886,-0.0025384943,0.03089225,0.00026234254,-0.015612212,-0.025124488,-0.026891055,-0.026845759,0.0021968829,-0.0055299546,-0.045658927,0.028446237,0.0068926257,-0.007613596,-0.008779982,0.018058226,-0.0050316923,-0.0064623086,0.035784278,0.005643196,-0.008968717,-0.021606456,-0.025169786,-0.0058017336,0.006337743,-0.030650668,0.011686511,0.009791605,-0.008772433,0.0019477519,-0.0066850167,0.02299555,0.035693686,-0.006065964,0.029503155,-0.021183688,0.02116859,0.022708673,-0.008621444,-0.0010965541,0.009391486,-0.006677467,0.010274769,0.0064925062,1.1080847e-05,-0.0013381357,-0.002302575,0.00946698,0.020307954,0.039257012,0.0037558393,-0.0021666852,-0.008719587,-0.018254511,0.0017967633,0.038049106,-0.005035467,0.012577344,-0.023629703,0.03327787,-0.02867272,-0.00802504,-0.019673804,-0.009232948,0.010976865,0.030288296,-0.012041334,0.014751578,0.0064019132,-0.010327615,-0.016125573,0.016246364,0.008696939,0.018813169,-0.013845647,-0.022285905,-0.014804424,0.025970025,0.044269834,0.031345215,0.017408976,-0.032583322,-0.0029405013,0.01671443,0.011490226,0.041219864,0.005141159,-0.030243,-0.0129850125,0.012237619,-0.018903762,0.007979743,0.0328551,0.0031952944,-0.02128938,0.004427738,-0.0355125,-0.013724856,-0.022240609,0.017333481,9.8850294e-05,0.0010739058,-0.035784278,-0.054657843,0.008478005,0.0077608097,-0.027434614,0.009806704,-0.012766079,0.01472893,0.018782971,0.034787755,0.0012296127,-0.008606345,-0.010191725,0.0096708145]	2025-06-21 20:56:23.484783-04	0
content	04c3d6df-919c-4677-b993-dfaeccb3045b	[-0.007248864,0.018271739,-0.0071644853,0.0032811656,0.005795256,-0.013753665,0.02752267,0.063636586,-0.020665014,0.018716643,0.04001066,-0.06688899,-0.037494652,-0.037832167,-0.04059364,-0.0019205654,-0.07136871,-0.030698363,-0.034978643,-0.0059640124,-0.017090444,0.0013107404,-0.024623124,0.059678476,0.053756654,-0.0021861652,-0.019575767,0.027445963,-0.01778081,-0.025835104,0.02425493,-0.01564067,-0.04550292,-0.01056263,-0.0034230745,-0.014720179,-0.013861055,-0.011674889,0.0081386715,0.00522762,-0.018271739,0.007129967,0.04295623,0.020480916,-0.030821094,0.016691564,0.007187498,-0.042465303,-0.010570301,0.05167021,-0.0688527,0.026280008,-0.0392129,0.010992193,-0.04955308,0.004146043,-0.017596712,-0.013561895,-0.017535347,-0.015725048,0.024699831,-0.014367325,0.030636996,0.032002393,-0.041790277,-0.024791881,-0.047896195,0.024346977,-0.01767342,-0.017320566,0.007747463,0.024761198,-0.0147508625,-0.014444033,-0.035776403,-0.009887604,0.0052161138,0.06290019,-0.0006299608,-0.03872197,0.0064319284,0.010079373,-0.03329108,-0.013454505,-0.040685687,-0.011536816,-0.023687292,-0.038261726,-0.056241978,-0.0067387586,-0.015909147,-0.032585368,-0.02112526,0.02020477,0.04194369,0.034579765,0.016492125,0.020358184,0.043078963,0.030437557,0.008552892,-0.01675293,-0.030038677,0.025804421,0.028044282,0.0027212005,0.011797622,0.02285885,-0.010248129,-0.0059946952,-0.115981825,-0.019882597,-0.039887927,0.004541087,-0.0524066,-0.036267333,0.01959111,0.0077973227,-0.010416886,-0.017029077,-0.045963164,0.040286805,0.012334575,-0.017397273,0.03411952,-0.054983974,-0.0069957287,-0.018501861,-0.054493047,-0.036328696,-0.022582704,0.03117395,0.03464113,-0.04071637,-0.033137664,-0.023227047,-0.016476782,-0.006719582,-0.018271739,-0.000711942,-0.004053994,-0.04461311,-0.033444494,0.012204172,-0.040378857,-0.030498924,-0.025927152,-0.004418355,-0.0017163315,-0.0059946952,-0.017719446,0.013239724,-0.04507336,0.012480319,-0.0056303344,-0.020235453,-0.008292086,0.046392728,-0.009925958,-0.039397,-0.0010010336,0.056886323,0.003131586,0.010217446,-0.048110977,0.043508526,-0.025574299,-0.022705436,-0.080696344,-0.06308429,0.0033482846,-0.025804421,-0.003432663,0.02529815,0.0062094764,-0.009902945,-0.027001059,-0.010217446,-0.02163153,-0.041145932,-0.031035876,0.0009785007,-0.051731575,-0.0039581098,-0.030100044,-0.03209444,-0.014298288,-0.0053541875,-0.013899408,0.0049016126,-0.005319669,0.025160078,0.050903134,0.032769468,0.041391395,-0.02752267,0.08763071,-0.011252998,0.030192094,-0.01877801,0.036727577,0.044398334,-0.016123928,-0.029670483,0.019453036,0.003518959,0.07627799,0.036482114,-0.04964513,0.0057223835,0.08026678,-0.036819626,0.019545084,0.028872723,-0.0459018,-0.02466915,-0.04731322,0.016430758,-0.005404047,0.059739843,-0.059555743,0.04967581,0.012879198,0.0014075836,0.0066543804,0.0002211335,0.025528274,-0.0052352906,0.023073632,0.007735957,0.034364983,0.005680194,-0.03525479,-0.044827893,0.025819762,-0.047374584,0.062010385,-0.016768271,0.024899272,-0.0141065195,0.02428561,0.003877567,0.024193563,0.031818293,0.009373663,0.021109918,-0.02690901,-0.03872197,0.0457177,0.027706768,0.04498131,0.009726518,0.029977312,0.039857246,0.043508526,-0.045932483,-0.013178358,0.035960503,-0.010294153,-0.036113918,0.017811494,0.04059364,-0.045963164,0.010263471,0.008775344,0.007314065,-0.009481054,0.00059256586,-0.01919223,-0.020634333,-0.0005561298,0.0059448355,0.011997062,0.0042074095,-0.003421157,-0.0347025,-0.0051394063,0.0102558,-0.013515871,0.05025879,-0.021294016,0.019268937,0.018670619,0.015364523,0.02365661,-3.3020206e-05,-0.0023376627,-0.0004918872,-0.048908737,-0.013968445,0.030836437,-0.018839376,0.019667817,-0.00011536097,0.002939817,0.00032552768,0.04832576,0.049276933,0.015257132,0.01735125,0.035960503,-0.08419421,0.0072296867,-0.02284351,0.027752792,0.06909817,-0.05931028,-0.0327081,0.026157277,-0.017197834,-0.036574163,0.020634333,0.016983053,-0.03810831,-0.055290803,0.0032581533,0.040685687,-0.022076434,0.0048901066,0.0029858416,-0.026249325,0.006539319,-0.0126951,0.01747398,-0.038261726,-0.0170751,0.032309223,-0.0028861216,-0.00904382,-0.0440915,0.02315034,-0.0003713125,-0.02172358,0.010554959,-0.00964981,-0.03439567,-0.025175419,-0.020956503,0.0046906667,-0.0030548782,-0.052928213,-0.038323093,-0.014198568,0.016614856,-0.020327501,0.0017613972,0.014612789,0.00853755,-0.0262033,0.0022245192,-0.0253902,-0.037494652,0.011130266,0.0063628918,-0.001096918,0.038936753,-0.008184696,-0.0050818752,-0.006428093,-0.015556292,-0.060292136,0.024531076,0.0361446,0.01635405,0.015287816,0.010777411,-0.063329756,-0.0006884503,-0.009619127,-0.013331773,0.0065546604,-0.007862524,0.03191034,0.009266272,-0.040992517,-0.03473318,0.00984925,-0.007080107,-0.014336642,0.06351385,-0.0180723,-0.020250794,0.012748796,-0.036420748,0.006784783,0.009481054,0.002761472,-0.035408206,-0.08081908,0.02345717,0.01655349,-0.058757987,-0.037954897,0.0092739435,0.020787748,0.0076707555,0.023978781,-0.005411718,0.043324426,0.04620863,0.02163153,0.0055306144,-0.022935558,-0.016676223,-0.0041076895,0.00063811097,0.03890607,0.03066768,0.0010451404,0.019545084,0.065784395,-0.037832167,0.042772133,0.004851753,-0.03138873,-0.00533501,0.01502701,0.015264804,0.03421157,0.081985034,0.005331175,-0.04854054,-0.0069113504,-0.017688762,-0.047896195,0.036390062,0.02497598,-0.005350352,0.024730515,-0.058819354,-0.06443434,0.013891738,0.041575495,-0.062654726,0.014888936,-0.005657182,0.017612055,0.011843646,0.0071951686,0.025973178,0.03746397,0.0016655128,-0.042127788,-0.016875662,-0.017719446,-0.03036085,-0.050964497,-0.010317166,-0.045748387,-0.06664352,-0.039335635,-0.008928759,0.05768408,-0.0059755184,-0.03706509,-0.028749991,0.047804147,-0.024822565,0.006267007,-0.011897341,0.014198568,-0.0052161138,-0.019253597,0.033751324,0.033751324,0.015019339,-0.0046791607,0.011736256,0.015709708,0.007586377,-0.009143541,0.009327639,-0.025037346,-0.015985854,-0.02690901,-0.036328696,-0.000906108,0.010409215,0.00025217608,0.0108541185,0.0063091964,-0.03137339,0.01066235,0.026126593,0.0009214495,-0.016292684,-0.04154481,-0.022705436,0.02242929,-0.0015245626,-0.0044758855,0.0018342694,0.060169406,-0.01877801,0.045932483,-0.01137573,-0.0205116,-0.01908484,0.0006405081,0.004702173,-0.0025907976,-0.0459018,-0.030253459,0.03362859,0.009665152,-0.0103862025,0.033843372,0.02385605,0.030821094,0.044244915,-0.009726518,0.006466447,0.011552158,0.040164076,-0.0024853246,0.02670957,0.015402877,0.085544266,0.018348446,0.013930092,0.012181159,0.008215379,0.025098711,-0.0010825354,-0.014743192,-0.028182356,-0.02558964,-0.030268801,-0.033720642,-0.026786277,0.027691428,0.012633734,0.0069190213,-0.009389005,-0.07020275,-0.019054156,-0.015909147,-0.025819762,-0.038814023,0.009488724,0.023181023,0.034027472,0.018394472,0.03697304,-0.009841579,0.010731387,0.00018889236,-0.005361858,-0.006217147,0.035960503,0.08401011,-0.017811494,0.018977448,-0.017704103,-0.0015456572,0.025911812,0.016384734,-0.007532682,0.036205966,0.0010691115,0.029977312,-0.0022897206,0.011797622,0.012158147,-0.020388868,0.0170751,0.011030546,0.012349916,0.013063297,-0.00695354,-0.00670424,-0.014720179,0.01787286,-0.0076208953,0.023242388,-0.005687865,0.04436765,0.016507465,0.010570301,0.03411952,-0.019284278,-0.025835104,-0.01778081,0.008353452,-0.03301493,0.025804421,-0.032861516,0.02183097,0.0021075401,0.008246062,0.012472648,-0.013876396,-0.026264666,-0.013178358,0.0071222964,-0.001109383,0.012096781,-0.048141662,-0.015702037,0.018824033,0.0065431544,0.012549356,-0.031450097,-0.0011400661,-0.026847644,-0.006366727,-0.0055076024,-0.0016549655,0.013623262,-0.013285749,-0.0034249923,0.00051442004,-0.014597448,-0.050412204,-0.04182096,0.0120124025,-0.015817098,0.008667953,0.04863259,-0.0012110205,-0.0047750454,-0.004506569,-0.0030548782,-0.0019253596,0.009596115,0.022644069,0.00018481727,-0.05139406,-0.0074483035,0.0119893905,0.0059678475,0.033966105,0.026602179,-0.005779914,0.009611457,-0.024791881,-0.024316294,-0.0112990225,0.032769468,-0.068668604,0.007697603,-0.001793039,-0.0023836873,-0.009780213,0.0077206152,-0.007900878,0.0033195193,-0.031419415,-0.01177461,-0.0024028642,-0.03715714,-0.054032803,0.042127788,0.001855364,0.027139133,-0.0026579166,0.0043531535,-0.01991328,-0.003764423,0.02253668,-0.020235453,-0.0020845279,-0.043876722,-0.014490057,-0.0063513853,0.012219513,0.0027154475,0.029179553,-0.0012100616,-0.0010739057,-0.0491542,-0.020879796,0.036267333,0.003950439,0.0054002116,-0.025620323,0.0023587572,-0.024040148,0.050626986,-0.013508201,-0.006949704,0.024178222,-0.07179827,0.010907814,0.044398334,-0.0061902995,0.016814295,0.020803088,0.022598045,-0.021539481,-0.019514402,-0.00452191,-0.0008433037,-0.028765332,-0.0015264803,-0.0021228816,-0.009527078,0.02772211,-0.014689497,-0.11260669,-0.017688762,0.021846311,-0.010623996,-0.023227047,0.007628566,-0.014344312,-0.0042917877,0.02253668,0.03866061,-0.006938198,-0.05381802,-0.037341237,-0.0068883384,0.01412186,-0.012112123,-0.016215976,0.01920757,0.008644941,-0.008790686,-0.022352582,-0.034272935,-0.01593983,-0.00070954487,-0.004893942,-0.004073171,-0.06750265,-0.019729182,0.022168484,-0.049798544,0.03128134,0.011905013,-0.020419551,0.0115674995,-0.053265724,0.0041000186,0.020526942,-0.03605255,-0.026632862,-0.034610447,-0.007613225,0.012472648,0.020695698,0.03482523,0.039397,-0.014781546,-0.007709109,0.023319095,0.0063091964,0.007444468,-0.015786415,0.0021574,0.017121127,-0.034242254,-0.0033923916,0.0048172344,-0.0039350977,0.0036263496,-0.00294557,-0.0045640995,0.025144735,0.023840707,0.025819762,0.0039581098,0.035193425,0.007099284,-0.012810161,0.036788944,0.023533877,0.0042994586,-0.011674889,0.005687865,0.0021708237,0.009511736,0.0024949133,0.019130863,-0.003285001,0.024607783,-0.010064031,0.00047966192,-0.004176726,0.011628865,0.027676085,-0.0035630658,0.029609116,-0.0024508063,-0.048356444,-0.0048287404,-0.020235453,-0.020220112,0.0005057904,-0.019989988,-0.032247856,0.009166553,-0.006485624,-0.014336642,0.017566029,0.02091048,-0.108065605,0.02598852,0.057223834,-0.019483719,0.0071453084,-0.005779914,0.03816968,0.019238254,-0.014505398,-0.040562954,0.020542283,-0.026464107,-0.030038677,-0.0055612978,0.0050320155,-0.03006936,-0.023610584,-0.01666088,0.009404346,-0.034886595,-0.030406874,0.0053695287,-0.0147968875,0.02029682,-0.022168484,-0.015801756,0.013178358,0.03841514,-0.0032102112,-0.024346977,-0.02072638,0.020496259,-0.016215976,0.036512796,-0.032339904,0.03445703,-0.016430758,-0.004755868,0.014781546,-0.016016537,0.00071481854,-0.018302422,0.04467448,-0.035807084,0.0022341076,0.016783612,0.025160078,-0.027169816,6.669961e-05,0.02976253,-0.008614258,0.022628728,-0.021923019,-0.016875662,-0.002218766,0.023503194,-0.0050818752,-0.007632402,0.028136332,0.027430622,-0.008223049,0.013523541,0.009534749,-0.000120035336,0.009151211,0.007969915,0.010041019,0.025114054,-0.008468514,-0.001010622,-0.005653347,0.023840707,0.022874193,0.030100044,0.013347114,-0.020833772,0.028443161,0.02710845,0.0015322334,-0.02862726,0.030268801,-0.053235043,-0.031005193,0.004974485,-0.04203574,0.02833577,-0.015863122,0.0028611918,0.014068166,0.0020116556,0.036574163,-0.04485858,-0.00041182368,-0.01776547,-0.005898811,-0.024653807,-0.0196985,0.01877801,0.04660751,-0.010470581,0.037832167,-0.0015744226,-0.016584173,0.014551423,-0.027752792,0.00497832,-3.9672188e-05,0.003685798,0.011974049,-0.0042265863,0.00041182368,0.010179092,-0.009089845,-0.009488724,-0.0038449662,0.020189429,0.022505997,-0.026326032,0.010723716,-0.008384136,0.018302422,-0.028136332,-0.036236648,-0.0014651143,-0.016093245,0.004702173,0.010110056,0.0129252225,-0.010923156,-0.039765194,-0.018440496,0.01890074,-0.008621929,0.005323504,-0.0086296,0.012971248,-0.003549642,0.01036319,-0.011191632,-0.004744362,0.0035458067,-0.028167013,-0.043078963,-0.0051048878,-0.0106086545,-0.03209444,-0.011391072,-0.012104452,-0.0035764896,0.024485052,0.011137937,-0.007076272,-0.0036819626,0.023825366,0.012863857,0.01624666,0.0044567087,-0.031542145,-0.025727713,-0.006550825,0.0410232,0.023119656,0.013047955,-0.004598618,0.0024757362,-0.036420748,-0.01086946,-0.0072258515,-0.009680493,0.03869129,-0.023733318,0.030928485,0.054891925,0.024607783,0.021508798,0.032861516,0.023748659,0.035316158,0.029286943,0.019054156,0.0042304215,0.036543477,-0.016737588,0.02934831,0.007287218,-0.021570165,0.0045717703,0.022383263,0.0058566215,0.008253733,0.030606315,-0.011214645,0.01960645,0.035929818,-0.016921686,-0.015924487,0.014743192,-0.010792753,-0.04059364,0.00079296436,0.011789951,0.022076434,-0.010294153,-0.019038815,-0.0066428743,0.019575767,-0.007613225,-0.018670619,-0.010754399,-0.008338111,-0.003923591,-0.021524139,-0.02103321,-0.0015427807,-0.023472512,0.023472512,0.005005168,0.043692622,-0.033229712,-0.032769468,-0.022275874,-0.01340848,-0.046883658,0.013362456,-0.018317765,0.032922883,0.0017920802,0.009872262,0.0070417533,0.00018110174,0.022475313,-0.018149007,0.0013778594,0.027292548,0.020941162,-0.003357873,0.007854854,-0.01248799,0.015878463,0.005595816,-0.001984808,0.008767674,0.011160949,-0.025359517,-0.0047060084,0.0011381484,0.023395805,0.006896009,0.0024105348,0.010340178,-0.00051681715,0.04154481,0.032585368,0.018425154,0.018026276,-0.01198172,0.020465575,0.028090306,-0.0049821557,-0.011391072,-0.002680929,-0.012641405,-0.013554225,-0.00792389,-0.004257269,-0.026586838,-0.02203041,0.00934298,0.024024805,0.03645143,0.007363925,0.036390062,0.0038372953,0.011943366,-0.033782005,-0.0057415604,-0.04967581,0.019989988,0.01738193,-0.0069842227,-0.029486384,-0.015633,-0.019284278,0.013853384,0.017151808,-0.007962244,-0.027967574,-0.007172156,0.031664878,-0.001959878,0.007390773,0.025221443,0.0012340328,0.010071701,-0.02428561,0.009887604,-0.0047788806,0.0037970238,0.0027595542,0.006121263,0.007847182,0.043539207,-0.011628865,-0.033689957,0.029440358,0.0054692486,0.010501264,-0.04519609,0.024040148,0.019314962,-0.047589365,0.027001059,0.0069612106,0.0043186354,-0.0008586452,0.00024714216,-0.019637134,-0.008844381,0.00043771247,0.002126717,0.0021727413,0.019821232,0.02508337,0.045257457,-0.005941,-0.014244593,0.03157283,0.013669286,0.04317101,0.016093245,0.03586845,-0.011797622,0.005189266,0.021708237,-0.044521064,-0.01218883,-0.030483581,-0.005998531,-0.0009578856,-0.014950302,-0.025528274,0.021094577,-0.017596712,0.023073632,0.016215976,-0.012511002,-0.016430758,0.004882436,0.006194135,0.013508201,0.09493327,-0.0023069796,0.002433547,-0.0050818752,-0.013262736,0.026786277,-0.008560563,0.0083611235,0.004993662,-0.012633734,-0.017750127,-0.00452191,0.0031392567,0.0066160266,0.032892197,-0.023303755,0.00017163315,-0.013178358,0.009780213,-0.0076745907,0.028611917,0.023748659,-0.0030798083,-0.015602317,0.027553353,0.0012215677,0.020787748,-0.013899408,-0.0031162445,-0.0029072163,0.025743054,-0.021478115,-0.01738193,0.03951973,0.016415417,0.016292684,-0.031219974,-0.0033751323,-0.008038952,-0.012526344,0.021892335,-0.014850582,0.007505834,-0.00974953,0.023181023,0.0010499347,-0.010286483,-0.034272935,-0.037525333,-0.040072028,-0.03586845,0.016308026,0.0067387586,0.023978781,0.011851317,-0.0015609987,-0.016538149,0.044950627,0.0012953988,-0.005311998,-0.04995196,0.036482114,-0.019054156,0.025436224,-0.037709434,-0.03553094,-0.0035707366,-0.0021727413,-0.0070532598,0.028995456,0.0071414732,0.0033003425,0.04498131,-0.019130863,0.016814295,0.009066833,-0.028826699,0.013070967,0.01929962,0.015464243,-0.028657941,0.0044605443,-0.009642139,0.0077819815,-0.017151808,0.018655278,0.009611457,0.005576639,-0.02690901,-0.01929962,-0.033137664,0.011437097,0.023687292,0.058604572,-0.0014948385,-0.0028573563,-0.0345184,0.0044336966,-0.016891003,0.010202104,-0.01787286,0.02112526,-0.028980114,-0.031158607,0.0045756055,0.006834643,-0.051946357,0.01837913,-0.00036867568,0.008752332,-0.016507465,0.039151534,0.0076630847,0.010018007,-0.013761335,-0.012165818,0.040072028,0.0109001435,-0.019836573,-0.08155547,0.03319903,0.022107117,-0.0039734514,-0.00093535276,-0.006922857,0.0040079695,0.022199167,-0.041268665,0.0022571199,-0.02275146,-0.021585505,0.0035630658,0.0253902,-0.015893806,0.0038296245,0.04010271,0.0010374697,-0.025160078,-0.030683022,0.027016401,-0.009864591,0.037832167,0.017044418,-0.0073792664,0.010539618,-0.033076297,-0.009396675,0.008284416,-0.018026276,-0.0057415604,-0.0072335224,-0.012303892,0.027307888,0.018333105,0.00048853125,-0.02884204,0.012626063,-0.030652339,-0.010324837,0.0034115685,-0.00095117366,-0.031756926,-0.032063756,-0.041606177,0.008276745,-0.0067387586,-0.03037619,0.017029077,-0.0057262187,-0.006477953,-0.009826237,0.002205342,-0.033689957,0.0060445555,0.008752332,-0.037832167,0.0023127326,-0.0054845903,-0.030238118,0.011736256,-0.009795555,0.00014382666,0.021247992,-0.027737452,-0.021876995,0.022061093,-0.0019627546,0.0113220345,-0.034242254,-0.021892335,-0.023886733,0.004011805,-0.029517066,0.010938497,0.022015069,0.037095774,-0.018655278,-0.008744661,0.01228855,0.01564067,-0.046945024,0.0022456136,-0.021923019,-0.023349779,-0.02466915,0.041391395,0.011674889,0.00059016875,-0.008644941,0.03280015,-0.011145608,-0.014804558,-0.014888936,0.0028305086,-0.0038008592,-0.042526666,0.01248799,-0.0020423387,0.019744525,-0.031971708,-0.003716481,-0.0017776976,-0.0110995835,-0.027676085,0.011352718,0.024147538,0.031097243,-0.03724919,0.01778081,0.040501587,0.009994994,-0.020358184,0.030084703,0.025558956,-0.027645402,-0.015425889,-0.0010585643,-0.010884802,0.03169556,-0.0011180126,-0.03350586,0.023211706,0.007647743,0.028964773,-0.027307888,0.024837906,-0.00061893405,-0.025911812,-0.023764,0.007751298,0.0609058,0.008706307,-0.023579901,-0.0011793786,0.014459373,-0.017305223,-0.016691564,0.0027039412,-0.002897628,0.01664554,-0.050688352,-0.029087504,0.010064031,-0.00726037,-0.022015069,0.025405541,-0.025482249,0.010723716,0.014888936,0.0099412985,0.011038217,-0.026249325,0.0040079695,-0.004997497,0.015088376,0.026356716,0.0143059585,-0.006105921,-0.00904382,-0.05593515,-0.032953564,-0.009082174,-0.015241791,-0.021616189,0.0048402464,-0.017949568,-0.0017000311,-0.028151672,0.024346977,-0.002471901,-0.018977448,0.031542145,0.01147545,0.005760737,-0.022183824,-0.0015811344,0.0026981882,-0.0058451155,-0.00974953,0.025896471,-0.0034460868,-0.00095069426,0.0038315423,-0.011137937,0.013930092,0.04854054,-0.014029811,0.023380462,0.006232489,0.02680162,0.019284278,-0.020695698,0.01949906,-0.01147545,0.0035170414,-0.0047750454,0.004832576,0.015402877,-0.010010336,-0.010033348,0.009020808,0.018056959,0.034671813,0.011245327,-0.0020250794,0.005776079,-0.021401407,-0.0017144139,0.035132058,-0.020787748,0.037709434,-0.0015763402,0.023595244,-0.034303617,0.00043939045,-0.011705573,-0.038138997,-0.00031809663,0.025267469,-0.003087479,0.017750127,0.010102385,0.0133701265,-0.001109383,0.0013279995,0.02893409,0.004844082,-0.013086309,-0.013431492,-0.016369391,0.010278813,0.032431953,0.0028439325,-0.016200636,-0.04844849,-0.009588445,-0.0042802817,-0.0031450097,0.017504664,-0.0062593366,-0.01847118,-0.0032102112,0.017013736,-0.0009319968,0.00019164903,0.05878867,-0.01929962,0.0014804557,0.012119793,-0.023441829,-0.018348446,-0.028182356,0.023748659,-0.0067541003,-0.012441965,-0.01919223,-0.040992517,-0.007049424,-0.007007235,-0.011759268,0.030882461,-0.0296398,0.013224382,0.011828305,0.031634197,0.0052237846,-0.016461441,-0.0008701513,-0.0004425067]	2025-06-21 20:56:23.484783-04	0
content	9d7cc234-ae88-473c-827d-ba5e550421fe	[0.031067388,0.0269439,-0.008472924,0.030643743,0.025517624,-0.044285152,-0.025108099,0.063264504,0.012758812,0.04188449,-0.0053591244,-0.059988305,-0.035445068,-0.051769566,0.020603327,0.020730421,-0.039314367,-0.06365991,-0.04750486,-0.016734025,0.0096732555,-0.0005900156,0.0014403971,-0.006407649,0.033326834,-0.034993175,0.010548791,-0.0025189298,-0.026562618,-0.024260806,0.051515378,-0.027621733,-0.038636535,-0.026986264,0.0074138087,-0.013062425,0.010414636,-0.017214159,0.02942929,0.021874266,0.011678514,-0.029033886,0.038523562,0.019473605,-0.005913395,-0.020405626,-0.013994446,-0.013881474,0.005380307,0.029457534,-0.042957727,0.044878256,-0.023201691,0.011353718,-0.016479837,0.016423352,-0.002391836,0.013083607,-0.022354398,-0.007802151,-0.02475506,-0.026435524,0.01575964,0.0125752315,-0.053209964,0.025983633,-0.05473509,0.03567101,-0.04648811,-0.0070466488,0.0087624155,0.04521717,-0.014382789,-0.011982127,0.011932702,-0.06298207,0.024133712,0.09077326,-0.040189903,-0.011332536,-0.006792461,-0.05730521,-0.013090668,-0.020165559,-0.04722243,-0.0056980415,-0.007745665,-0.07399687,-0.043070696,-0.016790511,0.0031420428,-0.026336674,-0.021761294,0.029739965,0.013309551,0.010301664,-0.0031526338,0.009136637,0.036970194,0.045782033,-0.00056088995,-0.032225356,-0.010245178,0.023088718,0.015208899,0.0042858873,0.03391994,0.028638484,0.025559988,0.02081515,-0.079984404,-0.042392865,-0.047561347,0.006562986,-0.0067430357,-0.013140094,0.08054926,-0.021139946,-0.0038375286,-0.013401342,-0.013980325,0.00733614,0.0023582974,-0.014757009,0.0076326923,-0.024868032,0.0008971591,-0.007646814,-0.033581022,-0.029626992,-0.013669651,0.027748827,0.017553074,-0.026802683,-0.0053132297,-0.033411566,-0.016974092,-0.035247363,0.02219906,0.012716447,0.011572602,-0.03603817,-0.018583948,-0.011763243,-0.031095631,-0.023780674,0.033665754,-0.026167214,0.0018763996,0.010739432,-0.015138291,-0.0042752963,-0.043127183,0.022608586,-0.0045330143,-0.026407281,-0.00017365081,0.06710556,-0.009736802,-0.04939715,-0.024585601,0.020109074,-0.04499123,0.015293628,-0.044059206,0.01640923,0.017750775,0.009524979,-0.11692636,-0.027254572,0.01035815,-0.031829953,0.024161955,0.025630595,0.0022859243,0.011975066,-0.009129575,-0.007103135,-0.0065206215,-0.051289435,0.03400467,-0.020377383,-0.030559013,-0.027918285,-0.025715325,-0.0047271857,-0.023413515,-0.017821385,-0.016663417,0.056457918,-0.0093696425,0.05914101,-0.0071984553,0.0071737426,0.044511095,-0.011191321,0.033778723,-0.010315785,0.055525895,-0.10568561,0.010499366,0.03880599,0.013443707,-0.030107124,0.025432894,-0.006382936,0.019473605,0.050865788,-0.020589206,-0.039935715,0.05162835,-0.02722633,0.0125328675,0.0038375286,-0.04583852,-0.015561937,-0.022015482,0.05931047,-0.03338332,0.039173152,-0.045753792,0.06151343,-0.01823091,0.0022788637,-0.017200036,-0.015914977,0.024966883,-0.018739285,0.048352156,0.0011817964,0.006810113,0.01218689,-0.00031310102,-0.05015971,-0.008840084,0.014192148,0.014474579,-0.031434547,0.018315637,0.0022400294,-0.0064111794,0.02136589,0.049877282,0.012215133,-0.0018940516,-0.011876215,-0.020871637,-0.013803805,0.043014213,0.011671453,0.048888773,-0.016324501,0.05270159,0.013189519,0.026153093,0.015110048,-0.013740259,0.006820704,-0.0067783394,-0.008974239,-0.011975066,0.07201985,-0.06812231,-0.007823333,-0.0059840027,0.019869007,0.015999705,0.0040387604,0.03024834,-0.0007594741,-0.012229254,0.023258178,0.015816126,-0.02467033,-0.06829177,0.008585896,0.031858195,-0.021154067,-0.02540465,0.0026336673,0.016479837,0.017821385,0.047194187,-0.034710746,-0.0013027121,0.0181603,0.013493132,-0.008755355,-0.02290514,-0.04417218,0.023907768,0.0071808035,-0.009242549,-0.057587642,0.015477208,-0.004420042,0.0025206949,0.008550593,0.022439128,-0.01741186,0.042392865,-0.027932407,0.0013318377,-0.0093908245,-0.01981252,0.056514405,-0.07337552,-0.03897545,-0.005482688,-0.026379038,-0.053492393,0.024430266,-0.028709091,-0.046149194,-0.031378064,-0.02630843,0.04391799,-0.0016433942,0.0026654408,-0.03877775,-0.039681528,-0.01219395,-0.025037492,0.0049990253,-0.04151733,-0.043861505,0.0049849036,0.039766256,0.01467228,-0.08111413,0.025588231,-0.009560283,0.009687377,-0.021605957,-0.022227304,-0.0616264,-0.03685722,-0.020603327,0.009242549,0.016268015,-0.05702278,0.008465864,-0.053153478,0.007106665,-0.014312181,0.023582973,0.001027342,-0.032874946,-0.022707436,0.030389555,-0.007470295,-0.009821531,-0.002172952,-0.024260806,-0.037761,0.0506116,0.014884103,0.03335508,-0.020179681,-0.008063399,-0.02859612,0.08354303,0.022679193,0.05179781,0.017341252,0.02210021,-0.043240156,0.0365183,0.0013662591,-0.010852404,0.028850308,-0.0009964512,0.037083164,-0.0073785046,-0.027424032,-0.030643743,0.042647053,0.01604207,-0.015335993,0.0010802979,0.023060475,0.0103652105,-0.00733614,-0.046770543,-0.011177199,0.020405626,-0.014375728,-0.0020970488,-0.06637124,-0.0070713614,-0.013182458,-0.07105959,-0.013584922,-0.00787982,0.013408403,0.0018110876,0.041376114,-0.0087624155,0.039201397,0.055299953,0.017779019,-0.043042455,-0.04154557,-0.0013742024,-0.0016636939,-0.0043035396,0.024034861,0.028751455,-0.03778924,0.0012003309,0.050300926,-0.0804363,0.029175103,0.028115986,-0.036264114,-0.003904606,-0.028807942,-0.021958996,-0.016183285,0.042675294,-0.008381134,-0.033863455,-0.051035248,-0.038212888,-0.024529116,0.01549133,0.027240451,0.028553754,0.029514018,-0.07665172,0.014022689,0.00031464556,0.041008953,-0.04335313,-0.010534669,0.019402996,-0.018541582,0.011727939,0.032451298,0.045075957,0.0412349,-0.030926174,0.014587551,0.010245178,-0.022029603,-0.04767432,-0.011177199,0.03575574,-0.048436884,-0.024176078,0.024839789,-0.039483827,0.024176078,0.0064041186,-0.028793821,-0.012984756,0.043070696,-0.029372804,0.0011076584,0.043494344,0.00087377033,0.009433189,-0.036151145,-0.0030378965,0.004748368,-0.03024834,0.02043387,-0.0068877814,-0.020462113,-0.021648321,-0.0179626,-0.0070819524,-0.026830927,-0.0010396984,0.010111023,0.011791486,0.02200136,-0.0018287394,-0.022876896,0.026054243,-0.020702178,-0.033581022,-0.035558037,0.013288369,0.010118084,-0.025969513,-0.021803658,0.014036811,-0.034343585,0.0028437253,-0.008444681,0.011177199,0.06196532,-0.016338622,0.03547331,-0.029514018,-0.005161423,-0.020970488,-0.02355473,0.029655235,-0.0050025554,-0.052193213,0.00458597,0.041376114,-0.00041835062,-0.003585106,0.034682505,0.02539053,-0.022848653,0.030191854,0.00055250525,0.0004951365,-0.0060087154,0.045979735,0.0027713522,0.025658838,0.0060828533,0.014001507,0.012850602,-0.007943367,-0.0020741012,-0.023498243,0.023851281,-0.010492304,-0.004525954,-0.008953056,-0.043409616,-0.054198474,-0.056062516,0.008028096,-0.0046812906,0.0061569917,-0.013330734,0.018386245,-0.035558037,-0.0057015717,-0.016846998,-0.014813496,-0.039116666,0.010118084,0.007872758,0.027748827,0.03380697,0.00048586924,0.0030396616,0.030756716,-0.0053238207,-0.017623682,0.016211528,0.035981685,0.075409025,-0.008176371,-0.008183433,-0.0096732555,-0.011629089,0.019290024,0.029937666,-0.028793821,0.017101185,-0.015576059,-0.0005202905,-0.007159621,-0.004889583,0.006838356,-0.0023971314,0.027438153,0.0024518524,0.0069513284,0.023116961,0.017397737,-0.025771812,-0.011516117,0.04171503,-0.033298593,-0.0038304678,0.011205442,0.04420042,-0.021846022,0.013076547,0.01512417,-0.0190782,-0.06298207,-0.003134982,0.039003696,-0.050103225,0.007844516,-0.026435524,0.008395256,0.014884103,0.024613844,0.05015971,-0.0094120065,0.011629089,-0.026195457,-0.0024094877,-0.0034174128,0.003154399,-0.017129429,-0.018725162,0.014474579,-0.02925983,0.0038728325,0.0029355153,-0.0044977106,-0.06106154,-0.023300542,0.010259299,-0.031773467,0.01869692,-0.0020970488,-0.013902657,0.036603034,0.017256523,-0.016197408,-0.015745517,0.014884103,-0.04436988,-0.00027890044,0.038523562,0.005390898,-0.017016456,-0.016013827,-0.00027139834,-0.006735975,-0.028751455,-0.0066053504,0.01714355,-0.03914491,-0.010202813,0.010139266,-0.003869302,0.0053485334,-0.013034182,0.020024344,-0.019148808,-0.009179002,-0.032677244,0.027353425,0.0135708,-0.010125144,-0.010308725,0.0016795807,0.012829419,-0.028680848,-0.0011968005,-0.0060546105,0.001888756,-0.017044699,-0.0073078973,-0.008289345,-0.011311354,-0.03070023,0.020885758,0.036913708,0.023455879,0.014312181,0.020335019,-0.026492009,0.0046071527,0.01669166,-0.010054537,-0.019671306,-0.013648469,-0.0100192325,-0.03315738,0.002861377,0.040105175,0.023907768,0.005510931,0.0057898317,0.012518746,-0.014432214,0.011862094,0.0069266157,-0.010675885,-0.00375986,0.025376407,-0.020659814,0.033524536,0.0412349,-0.011163077,0.00038613586,-0.04668581,0.0068913116,0.023611216,-0.00944025,-0.0019505378,0.03216887,0.010202813,0.003510968,-0.023667702,-0.011148956,-0.028920915,-0.014982955,-0.005655677,-0.016762268,0.014319242,0.03649006,-0.031858195,-0.15002725,-0.013168337,0.013521375,-0.019388875,-0.027424032,-0.013704955,-0.060440194,0.016352743,-0.0038304678,0.021888388,-0.013302491,-0.049029987,-0.007865698,-0.013351916,-0.029598748,-0.008296405,0.0090660285,0.011043045,0.024119591,0.010859464,-0.023258178,-0.017058821,0.001449223,-0.01182679,0.013450767,0.005249683,-0.053181723,-0.02457148,0.026492009,-0.04581028,-0.0012409304,0.027268695,-0.014283938,-0.0031102693,-0.014997076,0.007858637,0.02200136,-0.05705102,-0.0036927827,-0.03380697,-0.038184647,-0.02328642,-0.014841739,0.040585306,0.02063157,0.008084582,-0.010774735,0.03849532,0.040557064,-0.008691808,-0.0069372067,-0.002208256,0.0141568445,-0.036235873,0.008677687,-0.019304145,0.018047329,-0.013535497,-0.0119256405,0.008917753,0.022848653,0.0067783394,0.02044799,-0.007106665,0.02548938,-0.008465864,-0.007470295,0.00010883515,-0.00540855,-0.025814176,-0.008698869,0.010457001,-0.009186062,-0.0025736508,0.0037986943,0.0071384385,0.01383911,0.023300542,0.004391799,0.02722633,-0.023710066,0.008162251,0.019544212,0.002089988,0.017920235,0.00021932517,-0.06151343,0.027014507,0.0018305046,0.015660789,-0.0014951181,-0.039512068,-0.007844516,-0.013521375,-0.007901002,0.020165559,0.036235873,0.009489675,-0.06275613,-0.0046424563,0.01660693,-0.011494934,-0.011982127,0.01256111,0.018075572,0.029033886,-0.015350115,-0.0059451684,0.016126798,-0.008006914,-0.019021714,-0.023724187,0.03730911,-0.028115986,-0.0070713614,-0.02191663,0.029372804,-0.048804045,-0.05628846,-0.0067818696,0.011953884,-0.00023940424,-0.0308132,-0.0025153994,-0.007085483,0.026110727,-0.00577571,-0.026746197,0.0047907326,-0.00733614,-0.03391994,0.039342612,-0.024712695,0.0029037418,-0.005528583,0.009786228,0.0061640525,0.007646814,0.007272593,-0.011480812,0.018442731,-0.029316317,-0.0024800955,-0.015689032,0.025093976,-0.025136342,0.017623682,0.02200136,0.045160685,-0.014065054,-0.011869155,-0.016324501,-0.023032233,0.018372124,-0.004596561,-0.04922769,0.0061464002,-0.0147428885,0.024910398,0.030728472,0.01714355,-0.017157672,-0.029175103,0.009969807,-0.023032233,0.010937133,0.03281846,-0.0056980415,-0.000731231,0.030643743,0.015703153,0.013069485,-0.011431387,-0.026449645,0.026506132,0.00870593,0.027579369,-0.06614529,0.042872995,-0.0073078973,-0.052503888,0.025898905,-0.03584047,0.026717955,-0.020377383,0.0015930863,0.013027121,0.018640433,0.014057993,-0.01742598,-0.0033432746,-0.032310084,-0.021704808,0.022594465,-0.039286125,0.022778045,0.032479543,0.006149931,0.02704275,0.02420432,0.0038339982,0.023215812,-0.030276582,0.015689032,0.023964254,0.0021394133,0.0154066,-0.010103962,0.011283111,0.0067783394,0.0013892065,0.005436793,0.0033821089,0.051317677,0.045527846,-0.018103816,0.020010222,0.015816126,0.022071967,-0.0021041096,-0.038212888,-0.0027431091,-0.016211528,0.00025749745,-0.010287542,0.015816126,-0.0036963131,-0.041969217,0.01953009,0.033665754,-0.007773908,-0.035614524,0.004547136,0.038467076,-0.018739285,-0.012631718,-0.004840158,-0.008677687,-0.022156697,0.0018216787,-0.039850987,-0.012716447,0.024246685,-0.024218442,-0.020758664,-0.0042399927,-0.035614524,0.031801708,0.008953056,-0.0144604575,-0.0006226717,0.029711721,-0.008536471,0.021987239,-0.0012153351,-0.031208605,-0.0113395965,0.019953737,0.012772934,0.035077907,0.03126509,-0.02347,0.00072372897,0.00061252184,-0.0030096532,0.0031596946,-0.016931728,0.019191174,0.0033203273,-0.0018834604,0.034993175,0.00055427046,0.046629325,0.014389849,0.041291382,0.022721559,0.024924519,0.037280865,0.030135367,0.019572455,-0.016380986,0.0197984,0.011706757,0.00051720144,-0.0064747264,0.05473509,-0.0010088076,0.024063105,-0.008896571,0.022128453,-0.001934651,0.0020105543,-0.005383837,0.0032197111,-0.011283111,0.038184647,-0.017891992,-0.016338622,0.050894033,0.013005938,-0.0001362508,0.0049213567,-0.03151928,0.008508228,0.009468493,-0.012490503,-0.020278532,-0.010238117,0.0010917716,-0.050470386,-0.020970488,0.0007290245,-0.018993473,0.022778045,0.037817486,-0.01869692,-0.016380986,-0.016734025,-0.0077174217,-0.006940737,-0.043070696,-0.01585849,0.003346805,0.012052734,0.014982955,0.0052849865,-0.0150676835,0.021831902,0.029824693,-0.0036098186,0.0060546105,0.05812426,-0.0018693389,-0.009645012,0.039512068,0.013260126,-0.006089914,-0.016889362,-0.043042455,-0.010880647,-0.00070210535,-0.005556826,0.0119256405,0.015378358,0.06433774,-0.009870957,0.010810039,-0.009362581,-0.010118084,-0.0004695412,0.01842861,0.030784957,0.04227989,-0.02925983,0.032959674,0.024613844,0.0119256405,-0.015081805,0.0064394223,-0.009503797,-0.024133712,-0.0023618275,-0.00096114737,-0.022227304,0.017256523,0.009094272,0.012525806,0.0061358092,-0.030502528,0.026435524,-0.015166534,-0.01732713,-0.022227304,-0.0042752963,-0.006630063,0.04273178,0.008303465,-0.0053026383,-0.023724187,0.0026477887,-0.015251264,0.041828003,-0.0073714443,-0.036970194,-0.015533694,0.0005931047,0.008670626,0.020744544,-0.017369494,-0.0035515674,0.002767822,0.004416512,-0.0013521375,0.009150758,-0.034258857,-0.013443707,0.02200136,0.021436498,-0.0044588763,0.04400272,-0.028087744,-0.03538858,0.03914491,-0.010061597,-0.022806287,-0.060440194,0.0045436057,0.008974239,-0.039766256,0.036377087,0.021930752,0.0070643006,0.010223995,0.0096944375,-0.026195457,0.023526486,0.0011844442,0.018951107,0.0140932975,0.007745665,0.026703833,0.01650808,0.0016098556,-0.017891992,-0.0021853084,0.015053562,0.022707436,0.023582973,-0.008261101,-0.008833024,-0.0064147096,0.012765872,-0.02034914,-0.015321871,-0.016790511,-0.009560283,0.011911519,-0.008840084,-0.019049957,0.0011509055,0.0040740645,0.017072942,0.008423499,0.009426128,-0.021394134,-0.028892672,0.00017276822,0.02942929,0.08670626,0.013168337,-0.0024730347,0.028666727,-0.013034182,-0.003080261,0.030728472,0.018824013,0.0068524773,0.011325476,-0.010499366,-0.016310379,0.018668676,-0.009249609,0.037732758,-0.0342871,-0.009150758,-0.017764898,0.00011175875,0.010534669,0.0044694673,0.04521717,0.012490503,-0.036744248,0.0048648706,-0.0052249697,0.02135177,0.0076115103,0.0036716005,0.023498243,0.0051720142,-0.01814618,-0.018824013,0.045979735,0.01549133,0.009779166,-0.016282136,-0.037648026,-0.007399687,0.012080978,-0.012130403,0.027833557,0.00238301,-0.0067783394,-0.017072942,0.017185915,0.01412154,-0.05044214,-0.03346805,-0.014728767,-0.023145204,0.021789536,0.011374901,0.008028096,-0.00394344,-0.0071101957,-0.0013362508,0.041658543,0.018809892,-0.008649443,-0.038918965,0.011572602,-0.030446041,0.016804634,-0.02191663,0.0020387974,-0.01906408,-0.010986558,0.008670626,0.03694195,0.012017431,0.0025736508,0.012398712,-0.004660108,0.032507785,-0.0059416383,-0.010033354,-0.004271766,-0.029118616,-0.0067253835,-0.033863455,0.01530775,-0.006608881,0.029683478,-0.027056871,-0.008607079,0.01823091,0.020504477,-0.036970194,-0.027169844,-0.0059981244,0.012349287,0.012222193,0.02465621,-0.011544359,0.0040846555,-0.052193213,0.026590861,-0.0043706167,0.006683019,-0.013959142,0.01421333,-0.052927535,-0.025178706,0.006400588,0.019600699,-0.04188449,-0.015660789,0.026237821,-0.01420627,-0.009284913,0.031660493,0.04069828,0.0011676749,-0.0007912476,-0.023441756,0.013330734,0.016225649,0.0043670866,-0.011424326,0.01227868,-0.013076547,-0.00095585175,-0.011586724,-0.0070113447,-0.009284913,-0.00797161,-0.016903484,0.007526781,-0.019473605,0.0071313777,0.020490356,0.02914686,-0.010315785,-0.0069513284,0.025009248,-0.030446041,-0.01953009,-0.01640923,0.010181631,-0.017482467,-0.018908743,0.008331709,0.027056871,-0.011410205,-0.059197497,0.01732713,0.022509735,-0.019332388,-0.016027948,0.012921209,0.009200184,0.034089398,0.0089813,-0.0069160243,-0.014559308,-0.020462113,0.0013697894,-0.008134007,-0.024260806,-0.016155042,-0.038212888,0.0038339982,-0.013902657,-0.0026672059,-0.0030414267,-0.0342871,-0.008840084,-0.017270643,-0.002721927,-0.0020176151,0.022537978,-0.025150463,0.011304293,0.010513486,-0.017087065,0.008953056,-0.015279506,-0.045612574,0.02026441,-0.014333364,0.019021714,-0.020490356,-0.034880206,-0.0048825224,0.012751751,0.004116429,0.0053344117,-0.018809892,-0.022439128,-0.015110048,-0.020645691,-0.012123343,0.032112382,0.033693995,-0.014884103,-0.030022394,-0.006675958,-0.0059345774,-0.019741913,-0.018654555,-0.0010211639,-0.013775563,-0.025051612,-0.034145884,0.01530775,0.008331709,0.021803658,0.002776648,0.00715256,-0.0414326,-0.023611216,0.013076547,0.0049849036,0.020871637,-0.03024834,-0.026237821,0.019177051,-0.011685574,0.004169385,-0.037026677,0.024543237,0.00029213936,0.0023688884,0.00047704327,0.0059734117,0.017764898,-0.029909423,0.015914977,0.0011526707,0.022749802,0.026421402,0.0038834235,0.026054243,-0.03188644,-0.04233638,0.010880647,-0.0044694673,-0.00953204,-0.0015074745,-0.003080261,0.008126946,0.014347485,0.019883128,-0.0010202813,0.02942929,0.016536323,-0.02869497,-0.01227868,-0.009609709,0.00090333726,0.022142576,0.016889362,0.004472998,0.02116819,-0.0034244736,-0.0016672243,-0.015477208,-0.027762948,-0.0010114553,-0.07269769,-0.010499366,0.019417118,-0.00944731,-0.039738014,0.007279654,-0.053661853,0.045895007,0.02026441,-0.011650271,0.01989725,0.009969807,-0.0024412612,-0.005366185,-0.014997076,0.030671986,0.008105764,-0.019770157,-0.009129575,-0.038721263,-0.03053077,-0.010584095,-0.02210021,-0.025828298,-0.00093290425,-0.01017457,-0.028920915,-0.0024959822,0.0075691454,0.013069485,-0.03482372,0.027240451,-0.00041636478,-0.013613165,-0.03098266,-0.002951402,-0.0051649534,0.017157672,-0.012921209,-0.013083607,-0.021973116,-0.00046071527,-0.0197984,-0.023399392,0.029372804,0.038890723,-0.028949158,0.034428317,-0.0060369587,-0.0035339154,-0.00031177714,-0.012434016,-0.0059628203,-0.01897935,-0.0044235727,0.005638025,0.0359252,-0.040952466,-0.008945996,-0.007689179,0.029937666,0.008190493,0.025065735,-0.00038503262,-0.006993693,0.007583267,0.02063157,-0.01549133,0.014629915,-0.015929097,0.018174423,0.02787592,0.029852936,-0.036885463,0.004254114,-0.020970488,-0.0125328675,-0.02236852,0.020151438,-0.022170817,0.019459482,0.009595587,-0.0038551805,-0.006005185,0.021846022,0.019304145,0.027183965,0.010591155,-1.1515123e-05,-0.0067218533,0.011311354,0.03527561,0.013161276,-0.0021747171,-0.0005997242,-0.00093466946,0.028723214,0.011332536,-0.002714866,0.024105469,-0.042590566,-0.0013503723,0.009058968,0.015180656,-0.0017616622,0.054593876,0.025531745,-0.021620078,0.007399687,-0.025277557,-0.012617596,-0.02740991,0.016366865,-0.019953737,-0.010245178,-0.051571865,-0.027325181,-0.012546988,0.02145062,0.0172424,0.015604302,-0.02355473,0.0056874505,0.013796745,0.009856835,0.0073643834,-0.004356495,0.00797161,0.022227304]	2025-06-21 20:56:23.484783-04	0
content	55992b0a-c309-40de-8b81-67fd7536ea54	[-0.0047931457,0.024947273,0.006507984,0.014597133,0.017507393,-0.038620148,0.011007048,0.049436234,-0.026688846,0.038895134,0.0511167,-0.033731524,-0.02862902,-0.027880449,-0.00899049,0.009296029,-0.05438597,-0.033334322,-0.03339543,0.02235019,0.041828312,0.0068669925,-0.009059236,0.054294307,0.056585852,-0.0062711914,-0.016942145,0.0142992325,-0.009868915,0.002054751,0.012595852,-0.025481965,-0.037520207,-0.0058319787,0.015620689,-0.0023583805,0.019325351,0.00738259,0.02123497,-0.0011104438,-0.017705994,0.009005766,0.037489653,0.0025054212,-0.005759413,0.024702841,-0.004449414,-0.011068156,0.018164303,0.040056184,-0.07852356,0.05618865,-0.026856892,0.029652575,-0.045953088,0.0072221817,-0.039720092,-0.0169727,-0.028384587,0.032631584,0.024397302,-0.035748083,0.03528977,0.016208852,-0.044608716,-0.02852208,-0.048794605,0.021387741,0.025543073,-0.007607925,0.020883601,0.01587276,-0.0029465433,-0.015299873,-0.023052929,-0.039200675,0.007913464,0.07167949,0.0023927535,-0.05930515,-0.008822443,-0.009716145,-0.0027956832,-0.015154742,-0.05102504,-0.009525184,-0.041461665,-0.04916125,-0.05398877,-0.0023488323,-0.019447567,-0.015735267,-0.029453974,0.0011247661,0.07552928,0.014933227,0.02239602,0.058877394,0.011786173,0.04558644,0.020807216,-0.0014331696,-0.012084073,0.013436085,0.01793515,-0.002551252,0.002967549,0.020058645,-0.008089149,-0.0051254192,-0.098566934,0.030645577,-0.04002563,-0.007115243,-0.0040560323,-0.047572445,0.022808498,-0.020898879,-0.019661445,-0.022273805,-0.053316582,0.016850485,0.011259118,-0.006462153,-0.0004270387,-0.07870689,-0.01059457,-0.016758822,0.004942096,-0.023587624,-0.009349498,0.017064363,0.06569092,-0.039903414,-0.02590972,-0.03153164,-0.0129395835,-0.020944709,-0.025634736,-0.0128020905,0.013222207,-0.037947964,-0.050230637,0.01501725,-0.0639799,-0.032356597,-0.012259759,-0.0025569808,-0.036420267,-0.014291594,-0.009876553,0.010739702,-0.053805444,0.05096393,0.032295488,-0.014581856,-0.011694511,0.04008674,-0.01732407,-0.068624094,-0.00969323,0.022808498,0.00823428,0.00738259,-0.042011634,-0.005912183,0.012641682,-0.023175145,-0.09502268,-0.041400556,0.004525799,-0.0850621,0.0019096198,0.018042088,0.020241968,-0.022258528,-0.0017167481,-0.03690913,-0.021540511,-0.040728368,-0.035931405,-0.009349498,-0.045983642,-0.02907205,-0.04885571,-0.034587033,-0.008348857,-0.021800218,-0.009372413,0.02450424,0.012893752,0.013749262,0.07155727,0.01692687,0.0035404349,-0.008249558,0.08463435,-0.009166175,0.0049879267,-0.0128861135,0.004636557,0.039811753,-0.0059236404,-0.0639799,0.029453974,0.004415041,0.056066435,0.0076613943,-0.075101525,0.006889908,0.10754979,-0.053469352,0.030202545,0.031898286,-0.04525035,-0.04463927,-0.04549478,-0.013703431,-0.0054424163,0.040942248,-0.026429137,0.054263756,0.019157305,-0.016850485,0.002917899,0.026077768,0.055760898,-0.041950528,0.041614432,-0.00878425,0.026627738,-0.013359699,-0.031653855,-0.0725961,0.024580626,-0.045128133,0.04549478,-0.004590726,0.014092994,0.00030697137,0.016896315,0.02184605,0.053622123,0.008662035,-0.000946694,0.010525824,-0.05313326,-0.05227775,0.006439238,0.04353933,0.06101617,0.003676018,0.02641386,-0.0124965515,0.0030611204,-0.035534203,-0.025481965,-0.0135583,-0.0067562344,-0.044455945,-0.0012250211,0.028033217,-0.059274595,0.037428547,0.004036936,0.009021044,-0.021708557,0.012313228,-0.023083484,-0.041644987,-0.013703431,-0.017782379,0.0088911895,-0.0060420367,-0.021112755,-0.042928252,-0.013940224,0.0066645727,-0.03385374,0.016040806,-0.022365466,0.036175836,0.052858274,-0.014551302,0.017874042,0.010197369,0.0098612765,0.0119694965,-0.040820032,-0.014367979,0.0013882936,-0.022869606,0.014085355,-0.019401737,0.0004272774,-0.012381975,0.021525234,0.021525234,-0.011488272,0.02160162,0.031164994,-0.04424207,0.013390253,-0.006985389,-0.008929382,0.04769466,0.005228539,-0.015842205,0.014956142,-0.037795193,-0.028613742,0.060038444,0.0062444564,-0.046686385,-0.04555589,-0.013611769,0.034739804,-0.0271166,-0.0005012752,-0.02500838,-0.040789478,-0.0028587007,-0.007898187,-0.014169378,-0.05212498,0.011465357,0.024840333,0.024076486,0.017950425,-0.037734088,0.0741238,-0.013733985,0.008814804,0.037734088,-0.007905826,-0.015544305,-0.026261091,0.039628427,0.0101668155,0.022304358,-0.055058155,-0.018973982,-0.0011810998,-0.003941455,-0.02169328,-0.02235019,0.01898926,0.0320205,0.02927065,0.007164893,-0.026337475,-0.00924256,0.010036961,0.03409817,-0.010380693,0.012290313,0.014788095,0.0045716297,0.017629609,-0.0048084226,-0.03455648,0.0047664107,0.04741968,0.020929432,0.0043004635,0.036542483,-0.011274395,-0.0137721775,0.017599056,0.00083784567,0.007546817,-0.014574218,0.018790659,-0.004098044,-0.05912183,-0.05961069,0.0029580009,0.014780457,-0.009051598,0.052399967,0.015292235,-0.018240688,0.024993103,-0.010579294,-0.0073405784,0.023557069,0.035625864,-0.04033117,-0.086100936,-0.017140746,0.011243841,-0.053774893,0.0007184944,-0.009059236,0.034923125,0.043050468,0.024870887,0.027192986,0.040728368,4.330212e-06,-0.0073443973,0.0021158587,-0.028934559,-0.009143259,-0.011274395,-0.0026352752,0.032509368,0.019921154,-0.010525824,0.03078307,0.03489257,-0.016132468,0.032631584,0.0028281468,0.011404249,-0.01993643,0.011557018,0.01958506,0.058632962,0.05624976,-0.03183718,-0.045433674,0.009280751,0.0035939044,-0.03700079,-0.008852997,0.036848024,-0.026031936,0.015605412,-0.053499907,-0.057563577,0.019493397,0.041553326,-0.0440893,-0.02707077,-0.039353445,0.012687514,0.05704416,0.046991922,0.011106349,-0.0057479553,0.01938646,-0.052613843,-0.032051057,-0.026230536,-0.010961217,-0.041858863,-0.015704712,-0.027895724,-0.039628427,-0.0202878,-0.0018485119,0.05206387,0.021433571,-0.015933868,-0.081517845,0.039750643,-0.029194266,0.02173911,-0.0008769929,0.025665289,0.01802681,-0.0054347776,0.02204465,0.012641682,-0.0029350854,-0.046044752,0.011045241,0.0068364386,0.0013185925,0.034464817,-0.00044064474,-0.029010942,0.0022514416,-0.034739804,0.008348857,0.023557069,-0.0026047213,-0.032356597,-0.009433522,0.0025493423,-0.036328606,0.0052781887,0.030752515,0.021937711,0.03400651,-0.014390894,-0.016132468,-0.010235562,0.019111475,0.003991105,0.012542383,0.06532427,-0.019814214,0.024840333,-0.029545637,0.005793786,0.0022972724,-0.018408734,-0.0050413962,0.010189731,-0.047389124,-0.052949935,0.07167949,0.014459641,-0.013214569,0.021937711,0.013543023,-0.023908438,0.028063772,-0.04353933,-0.009746699,-0.0017568502,0.025695844,-0.0074742516,0.019401737,-0.015460282,0.06837966,0.01743101,0.007913464,0.016086636,0.011641042,0.0071839895,-0.0100446,-0.013145822,0.00062205864,-0.04473093,-0.06752415,-0.033059336,-0.036786914,0.006760054,-0.010823725,0.0065690917,0.016178299,-0.05921349,-0.011694511,-0.030691408,-0.038375717,-0.049650114,-0.007019762,-0.0030286568,0.043019913,0.037397992,0.028797066,0.0018103195,-0.033303767,0.00848635,-0.017965702,0.0012727615,0.0006841213,0.073084965,-0.023633454,0.0126340445,-0.0017749915,-0.0020776663,-0.006744777,0.0037982336,-0.009868915,0.031241378,-0.0053660315,0.026398582,-0.015628329,0.016056083,0.0067676925,-0.013879117,0.0014599042,0.016101914,0.009509906,-0.0017711723,0.046991922,-0.02079194,-0.027590185,0.022258528,0.035137,0.058266316,-0.0043119215,0.031562194,-0.0037524027,0.046105858,0.013871478,-0.02746797,-0.028812343,-0.022105757,0.0031604206,-0.03032476,-0.0044837873,-0.009341859,0.046869706,0.006855535,0.03032476,0.033303767,-0.0070274007,0.0018236869,-0.0042966446,0.002369838,-0.0006168072,0.0037084816,-0.028827619,-0.024443133,-0.0055417162,0.004510522,-0.0043004635,-0.03128721,-0.007275651,0.0056868475,-0.00793638,0.014070078,0.0073023858,0.0066722115,-0.02118914,-0.015994975,0.012473636,-0.0043119215,-0.053561013,-0.017782379,0.0058930865,0.014673518,-0.012985414,0.064713195,-0.005312562,-0.011954219,0.005595186,-0.003168059,0.01119801,0.0076613943,-0.0055264393,-0.02013503,-0.04415041,-0.038956244,0.009219644,0.015475558,0.028048495,0.026199983,-0.0023488323,0.035931405,0.0006583414,0.009364775,-0.005789967,0.025329197,-0.029438697,0.014704072,-0.0016518211,-0.011381334,-0.029056774,-0.021387741,0.0016756913,-0.020028092,-0.018164303,-0.019172583,-0.013298592,-0.034678694,-0.018668443,0.045372564,0.0041667903,0.018087918,-0.022594621,-0.027101323,-0.01571999,-0.014971418,0.023648731,-0.025100041,-0.0039643706,-0.02676523,0.00084691634,0.00014429564,0.019279521,-0.008012764,0.0062062643,-0.012542383,0.022732113,-0.06837966,0.02219742,0.027559632,-0.011159818,-0.012695152,-0.010869555,0.006832619,-0.053866554,0.054905385,-0.0103883315,-0.020012815,0.01511655,-0.04158388,0.022777945,0.032417703,0.02239602,0.0382535,0.02109748,0.017492117,-0.039658982,-0.025375027,-0.004961192,0.0127180675,-0.044914257,0.00537367,0.0054920665,-0.027773509,0.05719693,-0.010189731,-0.15448059,-0.0029599105,0.021250248,-0.029835898,-0.018118473,-0.013520108,-0.017339347,-0.025436135,0.011205649,0.049589004,0.0010598389,-0.039781198,0.0048886263,0.004575449,0.008379411,-0.028965112,-0.011274395,0.01410827,-0.038100734,-0.00046308278,-0.02265573,-0.0059618326,-0.025680566,-0.0017854944,-0.0126340445,0.015674159,-0.021204418,-0.013680516,0.021922434,-0.030951116,0.007099966,0.008448157,-0.025619458,0.030401146,-0.03293712,-0.0072489167,0.013604131,-0.021082202,-0.006870812,-0.023343192,-0.0061909873,0.014177017,-0.0043501137,-0.0022781764,0.038345166,-0.015032526,-0.012893752,0.023541791,0.041950528,-0.00022748346,-0.008219004,-0.0017893137,0.016453283,-0.0074207825,-0.0013214569,-0.023282085,-0.005698305,-0.019279521,-0.013986055,-0.017721271,0.051544454,0.0133291455,0.057166375,-0.0040025627,0.033975955,-0.0011963767,-0.015635967,0.04008674,0.012015327,0.019417014,-0.024320917,0.018607335,-0.010059876,0.02224325,-0.022564067,0.03260103,-0.031348318,0.014849203,0.015024888,0.0119694965,-0.017171301,0.0030267474,0.011045241,0.0016184027,-0.012229205,0.0023583805,-0.055822004,0.011503549,-0.026398582,-0.006863173,0.001391158,-0.044364285,0.0034182193,0.008692589,0.0061298795,0.009395329,0.023587624,-0.0071114236,-0.106938705,-0.0013882936,0.05389711,-0.01320693,0.010861917,0.01285556,0.0038192396,0.008409965,-0.024748672,-0.009525184,0.024626456,-0.02329736,6.588188e-05,-0.0077912486,0.024137594,-0.036542483,0.0029102606,-0.012473636,0.012786814,-0.010120984,-0.009265475,-0.018347627,-0.01908092,0.029988669,-0.015674159,-0.041919973,0.0043157404,0.030263653,0.026429137,-0.029713683,-0.019982262,0.0129395835,0.012611128,0.011511188,-0.02590972,0.0018962524,-0.016789377,-0.0083641345,0.0038860762,-0.028797066,0.0017339347,-0.012458359,0.056983054,-0.013795093,-0.0122750355,0.0012116537,0.01793515,-0.01250419,0.009402968,0.016682439,0.017599056,0.0077874293,0.011809088,-0.018851766,-0.019508675,-0.00064640626,-0.020975264,-0.028919281,0.032417703,0.010052239,0.009884192,-0.013489554,0.025924997,-0.018133748,-0.007447517,0.0302331,-0.0061757104,0.016850485,-0.027391585,0.0013262309,-0.004613641,0.014039524,0.035564758,0.024672287,-0.002917899,0.0018389638,0.023159867,0.027452692,0.0025531615,-0.019921154,0.037672978,-0.037550762,0.011167456,0.033823185,-0.008532181,0.037611872,0.012993053,-0.012618767,-0.021051647,0.029637298,0.018301796,-0.031012224,-0.01802681,-0.021998819,-0.0073176627,-0.02013503,-0.013863839,0.0059618326,0.052308302,-0.012336143,0.01135078,0.0014895034,-0.0016766462,0.0118854735,-0.02636803,0.01963089,0.0077797906,-0.022961268,-0.0104723545,-0.00063542597,-0.0033208288,0.0072527356,-0.01938646,0.022915436,-0.013733985,0.015949143,0.026474968,-0.010816086,0.035381433,-0.014482556,0.041797757,0.007157255,-0.03590085,-0.029606745,-0.025497243,0.01833235,-0.0032253477,0.018698996,-0.010877194,-0.023877885,-0.009479352,0.033303767,0.009341859,0.011266757,-0.0011639132,0.0054042237,0.004579268,-0.0055264393,-0.010014046,0.011014687,-0.0039032628,0.027406862,0.0082801115,0.002304911,0.01817958,-0.0306303,-0.010968856,-0.00031460985,-0.012825006,0.012565298,0.009525184,0.010205008,-0.011289672,0.01978366,-0.0024424037,0.009609207,-0.0072947475,-0.03339543,-0.029194266,-0.0075697326,0.02384733,0.030553916,0.0022724476,0.015284596,0.007798887,-0.021280803,0.0031776072,0.0059236404,-0.008631481,0.049283467,-0.009548099,0.0015983518,0.039842308,0.0022877245,0.025191704,0.04204219,0.013894393,0.01626996,0.012618767,0.032570474,-0.012817368,0.021555787,-0.028537357,0.016987978,0.013367338,-0.0042508137,0.023511238,0.01701853,-0.029484529,-0.018928152,0.01054874,0.013275676,-0.004724399,0.012061158,0.012443082,-0.02821654,0.032967675,0.018011533,-0.038131285,-0.023052929,0.0015926228,0.0055264393,0.011618126,0.0112209255,0.013130546,0.03690913,-0.023327915,0.008975212,-0.016636606,-0.0041515133,-0.0011515007,-0.026581906,-0.018912874,-0.0034735983,-0.006698946,-0.000122156,0.0127180675,0.025420858,-0.038986795,-0.055210926,-0.014245763,-0.027712401,-0.048641834,0.027987387,-0.019279521,0.019615613,0.019172583,-0.0115264645,0.0074513364,0.0064201416,0.003987286,0.0039147204,-0.0024786864,0.029438697,0.007890549,-0.020226693,0.003173788,-0.0032769074,-0.0012469817,0.019569783,0.016651884,0.01410827,0.002514969,-0.015238766,0.0105563775,0.00989183,0.03700079,-0.009593929,-0.018317072,0.00097295124,0.005912183,0.053041596,0.032967675,-0.0009323718,-0.00028906867,0.00507195,0.029805345,0.02917899,0.010793171,-0.0050795884,-0.028537357,0.0063552144,-0.00798221,-0.031806625,-0.012924306,-0.009800169,-0.004243175,0.014971418,0.009021044,0.034220386,0.019401737,0.01923369,-0.01807264,0.01501725,-0.0078103445,-0.0055264393,-0.013573577,0.0169727,0.03153164,0.012931945,-0.03302878,-0.014306871,0.00036020202,0.028552635,0.01501725,-0.012825006,-0.01300833,-0.020623893,0.0045219795,0.0041706096,0.0002444313,0.0300345,-0.012687514,0.022808498,-0.028873451,0.0035117907,0.0074589746,0.0038001433,0.034373157,0.008830082,-0.00061537494,0.028399864,0.003173788,-0.014895034,0.0094182445,0.0037944145,0.0003406284,-0.022854328,0.020364184,0.009624483,-0.03590085,0.02581806,0.020333631,-0.000755732,0.001275626,0.00021137104,-0.021173863,-0.011572296,0.005644836,-0.015949143,0.0049153613,0.028751235,0.019355906,0.036389712,0.0026199983,-0.009005766,0.030920563,0.03715356,0.029453974,-0.011862557,0.03892569,0.0029350854,-0.004162971,0.024091762,-0.041797757,0.021403018,-0.014138824,-0.0163769,-0.013443723,-0.02480978,-0.011717427,0.029163713,-0.011671596,0.02555835,0.018393457,-0.0067027654,-0.014711711,0.009066874,0.02610832,0.007542998,0.089950725,0.011839642,-0.0023526514,0.01943229,-0.004082767,0.04298936,0.0028587007,0.03565642,-0.034434263,0.009150898,-0.0017291607,-0.015483197,0.013902032,0.022182142,0.023266807,-0.023434853,-0.027865171,-0.030003944,0.015170019,0.0034640501,0.022823775,0.027208261,0.0048695304,-0.019157305,0.000397917,-0.0043004635,-0.0044417754,-0.0070732315,0.013741624,0.0090286825,0.012160459,-0.017369902,0.0024863249,0.033517644,0.007386409,0.018744826,-0.013795093,-0.008096788,-0.0059465556,-9.297461e-05,0.0031776072,-0.0048122415,0.0069930274,-0.02821654,-0.013374977,-0.003093584,-0.000697966,0.0012765807,-0.029240098,-0.032234382,-0.028292926,0.016132468,0.016407453,0.010174454,0.010785532,-0.028949834,-0.0108313635,0.023557069,0.0029045315,0.020501677,-0.046716936,0.042072743,-0.030202545,0.025115319,-0.0134666385,-0.01662133,0.007019762,0.0064354185,-0.019279521,0.017293517,-0.021326633,0.010632763,0.015658882,-0.0026658291,-0.003605362,0.0020471124,0.014184656,0.015147104,0.007913464,0.01953923,-0.038834028,-0.004747315,-0.009586291,0.0040560323,0.003746674,0.012786814,0.018347627,0.009372413,-0.032264937,-0.0068058847,-0.032723244,0.015674159,0.048641834,0.04635029,-0.011289672,0.015177658,-0.009548099,0.01381037,0.005133058,-0.008112065,0.0066913073,0.012832644,0.011946581,0.0083641345,-0.0047931457,0.007287109,-0.050658394,0.00027856577,0.00838705,0.010541101,-0.00788291,0.0054576932,0.027330477,0.0033322864,-0.0042393557,0.017339347,0.017201854,0.028735958,-0.009082152,-0.064041,0.020914156,0.023557069,0.0036301871,0.01943229,0.0022056107,0.0024233074,0.007508625,-0.0366647,-0.0038879858,0.007226001,-0.005854894,0.01587276,0.025665289,-0.0043883063,-0.0015926228,0.010357778,-0.021021094,-0.008112065,-0.020608617,-0.0043271985,-0.026001383,0.03302878,0.003956732,0.000964358,0.003731397,-0.026918,-0.00020182293,-0.008959936,0.027773509,-0.0067333193,0.0053813085,0.0002637662,0.02079194,-0.007642298,-0.013695792,-0.0042622713,0.0036511929,-0.0010751159,-0.0128861135,-0.003910901,0.0047931457,-0.048305742,-0.005839617,-0.014352702,0.024672287,1.7693821e-05,-0.031348318,-0.0044455947,0.00632848,-0.011159818,-0.000793447,0.012626406,-0.003821149,-0.0042546326,0.008264834,-0.03360931,-0.0064201416,0.0043615713,-0.025298642,0.0275138,0.015467919,-0.009632122,-0.028063772,-0.036328606,-0.00903632,0.01793515,0.004903903,0.011259118,-0.0014035705,-0.007966934,-0.011014687,0.004625099,-0.0234043,0.009349498,0.024397302,0.01973783,-0.013092353,-0.0011629584,0.011045241,0.039903414,-0.011388972,0.0024901442,-0.026918,-0.012374336,-0.0146047715,0.029698405,-0.0035671697,-0.033823185,0.030523362,0.00032511275,-0.008356496,0.013420807,0.0043959445,0.021005817,0.020608617,-0.027315201,-0.009761976,0.0010856189,-0.011427164,-0.03278435,0.0093342215,-0.022564067,-0.015483197,-0.026474968,0.0012698971,0.014329786,0.027849894,-0.032326043,-0.0098612765,0.011633404,-0.0044455947,0.014986696,0.008127342,0.0029694587,-0.016300514,-0.00049077225,-0.03174552,-0.014895034,0.0049955654,0.0016680529,-0.0021731472,0.016315792,0.017583778,-0.0056562936,-0.02079194,0.042317174,0.036389712,0.004785507,-0.010808447,-0.001335779,0.068624094,0.016728269,-0.0010273755,0.006194806,-0.015124188,-0.0035079715,-0.014833926,-0.030599747,-0.002872068,0.02645969,-0.051758334,-0.0038822568,0.025145873,-0.018698996,-0.027254093,0.02797211,-0.0127180675,0.005488247,-0.013031245,-0.018271241,-0.007821802,-0.01857678,0.01154938,-0.011152179,-0.029056774,0.016315792,0.0008249557,0.010655678,0.006832619,-0.033914845,-0.047786325,0.023541791,-0.03510645,-0.024030654,0.007210724,-0.01862261,-0.018194856,-0.021937711,0.008463435,0.025206981,0.014620049,0.017751824,-0.00016589821,0.023495961,-0.021387741,0.013390253,-0.009632122,0.018546227,-0.014291594,0.015781097,-0.008425242,-0.023022376,4.3294658e-05,-0.012305589,0.027590185,0.042836588,0.005243816,0.018912874,0.00040364586,-0.011060517,0.010151538,-0.007558275,0.015704712,0.011518826,0.029499806,0.017965702,-0.0015582497,-0.004036936,-0.028445695,0.012076436,-0.00436921,0.01872955,0.013176376,0.028949834,0.021998819,0.009746699,-0.006393407,-0.0033953039,0.024687564,-0.03388429,0.045219794,-0.0019764565,0.02610832,-0.04204219,0.0016795106,-0.007768333,-0.026215259,0.0049650115,0.012168097,-0.02716243,-0.012519467,0.02450424,-0.013733985,-0.015261681,-0.0031069512,0.011052879,-0.0074589746,8.8737645e-05,-0.008654397,-0.007497167,0.027009662,0.044028193,0.022212697,0.023068206,-0.032356597,-0.0033322864,-0.010289031,0.0034163096,-0.016728269,0.04457816,-0.048214078,-0.022059927,0.0031508727,0.016453283,-0.0085856505,0.04133945,-0.00989183,-0.026077768,0.00291217,-0.031959396,-0.02480978,0.005885448,0.021479404,0.00012388658,0.003525158,-0.018118473,-0.046472505,0.0053316583,0.015200573,-0.025451412,0.028185988,-0.010235562,0.028934559,0.02676523,0.010334862,-0.0008726962,-0.01712547,-0.008173172,0.0034984234]	2025-06-21 20:56:23.484783-04	0
content	70dc870f-f1bf-4291-98fd-25de3d96e3fe	[-0.010509089,0.02168948,0.0056781047,0.010149462,0.013897571,-0.03239836,0.005698084,0.049452655,-0.0055662207,0.025269764,0.046543676,-0.05495095,-0.02013909,-0.02806686,-0.015495911,0.00048050113,-0.040725715,-0.04862152,-0.004243594,0.017150193,0.01553587,0.011979562,-0.013721754,0.06668276,0.040853582,-0.011667886,-0.019931307,0.041812588,0.008798865,-0.013817654,0.02009114,-0.018876402,-0.03233443,-0.014401048,0.0053904033,-0.0054982915,0.0017332005,-0.01667069,0.024086991,0.007556155,-0.011556002,-0.011867679,0.046863344,0.015871521,-0.024758294,0.031519275,0.008862798,-0.019260004,0.010724865,0.033820886,-0.08650219,0.02924963,-0.039510977,-0.00029244638,-0.031247558,0.0034484197,-0.035547093,-0.010341263,-0.015144276,0.0067809597,0.019355904,-0.04251586,0.030400436,0.03618643,-0.065595895,-0.002469436,-0.046671543,0.023303805,0.025557466,-0.023383722,0.00025948058,0.020586627,-0.0022876249,-0.010780807,-0.029745117,-0.04580844,0.004655167,0.08790873,-0.01764568,-0.07352366,0.008615055,0.00088757847,-0.004163677,-0.024214858,-0.04241996,-0.01403343,-0.037529036,-0.025221813,-0.06434919,-0.019579671,-0.026995972,-0.00060936733,-0.06380575,0.013058442,0.039415076,0.025173863,-0.01145211,0.03797657,0.029073814,0.044849437,0.018061249,-0.025781233,-0.041333087,0.02544558,0.023479622,0.005718063,0.014025438,0.026132867,-0.0044913366,0.0035782848,-0.09251195,-0.006317441,-0.011987554,-0.0055702166,-0.015320094,-0.038775742,0.01732601,0.0034524156,-0.010964616,-0.019355904,-0.05121083,0.029297581,0.007284437,-0.01436109,0.010740848,-0.039415076,0.0039359136,-0.03487579,-0.01591148,-0.02103416,0.008223462,0.026005,0.04612811,-0.035419226,-0.023367738,-0.032829914,-0.02961725,-0.005486304,-0.027986942,0.022424718,0.0011418145,-0.015887504,-0.047886282,0.010301305,-0.052745238,-0.041045386,-0.011939604,-0.03228648,-0.042100288,-0.007576134,0.0047390796,0.013809662,-0.045265004,0.030240603,0.010964616,-0.032829914,-0.002471434,0.06035334,-0.025749266,-0.06422132,-0.0026392597,0.009925694,-0.008623047,0.004811005,-0.04168472,0.025461564,0.0043914407,-0.014824608,-0.09762664,-0.04500927,0.0094461925,-0.071477786,0.0067010424,0.012227305,0.019164102,-0.031743042,-0.012634882,-0.03398072,-0.007863835,-0.019979257,-0.04098145,0.011340226,-0.03858394,-0.0064932583,-0.019643605,-0.023767324,-0.01703831,-0.014632807,-0.024630427,0.012371155,-0.007340379,0.015543861,0.056261588,0.013322168,0.02379929,-0.03182296,0.08483992,-0.028945947,0.035227425,-0.013450036,0.02651647,0.048333816,-0.018173132,-0.057380423,0.026484502,0.003192685,0.035706926,0.013577903,-0.04900512,0.010069545,0.086630054,-0.028354561,0.03305368,0.03417252,-0.06345412,-0.071285985,-0.024854194,0.02074646,-0.011260309,0.066363096,-0.047151044,0.025045997,0.008319362,0.029185697,-0.005997773,0.012778733,0.022968153,-0.04149292,0.02431076,0.018189115,0.044274032,-0.00800369,-0.031854928,-0.04900512,0.02120998,-0.04101342,0.056868955,-0.014193264,0.008814848,-0.01581558,0.045328937,0.00403581,0.041460954,0.014441007,-0.002984901,0.026772203,-0.039255243,-0.06214348,0.016766593,0.023879208,0.07544167,-0.016606757,0.027763175,0.005969802,0.0069407937,-0.05012396,-0.02116203,0.013577903,-0.015855538,-0.01989934,-0.015152268,0.018556733,-0.043251093,0.021130063,0.036825765,0.011196376,-0.021146046,0.014017446,-0.013130368,-0.027795142,-0.012786725,0.00849518,0.033213515,-0.0041037393,-0.03262213,-0.03979868,0.0009849773,0.00826342,-0.021433746,0.016974377,-0.01285865,0.018524766,0.034747925,0.003895955,0.02806686,0.0043075276,-0.007172553,0.0040078387,-0.016414957,-0.021769399,0.014217239,-0.012794716,0.022616519,-0.05079526,-0.0151682515,-0.008287395,0.027139822,0.03046437,-0.0019849392,-0.010245362,0.042356025,-0.05853123,0.009070583,0.0022097058,-5.4537126e-05,0.044849437,-0.04948462,-0.03036847,0.0057060756,-0.021929232,0.007228495,0.026005,0.0045832414,-0.039926548,-0.034939725,-0.018924352,0.0667467,-0.038424104,0.010812773,-0.03271803,-0.025429597,-0.011444118,0.0015753644,0.01745388,-0.048078083,-0.00800369,0.025973033,0.007024707,-0.013561919,-0.028546361,0.04110932,-0.006884852,0.017102243,0.031806976,-0.024534527,-0.027907025,-0.02666032,0.030448386,0.015080343,0.030720105,-0.08241044,-0.014640799,-0.019052219,0.010157454,-0.03359712,0.009094558,-0.0070526777,-0.01619119,0.024071008,0.027619325,-0.013098401,-0.023847241,0.0016692668,-0.00011194627,-0.017805513,0.027491458,-0.01229923,0.004407424,-0.00872694,-0.016367007,-0.03497169,0.007863835,0.027011955,0.016926426,0.012515007,0.015751645,-0.039447043,0.0119236205,0.00035637998,0.0038779736,-0.010565031,0.01727806,0.0051146895,-0.020314908,-0.047342848,-0.034204487,-0.011532027,0.021002194,-0.0077559473,0.054535378,-0.010053562,-0.014872558,0.015599803,-0.023879208,-0.0032326437,0.019979257,0.031135673,-0.026356636,-0.09014641,-0.00056840986,0.032350414,-0.052169833,-0.01633504,0.023495605,0.032318447,0.032590162,0.0046511707,0.0020448768,0.053768177,0.0522018,0.017565763,0.0019389868,-0.05079526,0.012067471,-0.001692243,0.014417032,0.034492187,0.038136404,-0.024854194,0.027283672,0.06764177,-0.04641581,0.046032205,-0.018956318,-0.0076760305,-0.0026252742,0.012922583,0.028594311,0.033309415,0.04520107,-0.021417763,-0.055398483,-0.007959736,-0.0069248104,-0.02952135,0.018316982,0.050379694,-0.018157149,0.0040078387,-0.037848704,-0.04360273,0.01070089,0.05763616,-0.057572227,-0.0034284403,-0.0014395055,0.019148119,0.034044653,0.04718301,0.012507015,-0.00021939722,-0.002227687,-0.03826427,-0.024246825,-0.018556733,-0.02881808,-0.013561919,-0.011603952,-0.036250364,-0.08829233,-0.019835405,-0.03276598,0.03730527,0.011132441,-0.034204487,-0.04037408,0.065404095,-0.03276598,0.01713421,0.003949899,0.03022462,0.0017371963,-0.013969496,0.02646852,0.027347606,0.017949363,-0.012930575,0.04027818,0.008686981,0.0041716686,0.019052219,0.010820765,-0.03657003,-0.002879011,-0.029681183,-0.033533186,0.03206271,0.008806856,-0.0257173,0.012658857,0.008231454,-0.054055877,0.021897266,0.023479622,-0.0014564878,0.018460833,-0.008303379,-0.024822228,0.0044473824,-0.011140433,-0.001745188,0.011492068,0.05495095,-0.02144973,0.037113465,-0.016910443,-0.010924658,0.011220351,-0.012554965,-0.013985479,-0.008175512,-0.04187652,-0.0439224,0.048078083,-0.0016073312,-0.023447655,0.05290507,0.022264883,-0.02877013,0.04600024,-0.03228648,-0.023223888,-0.0054423497,0.04158882,-0.002469436,0.03500366,-0.010972608,0.06681063,0.023223888,0.012986517,0.0055702166,0.010565031,0.008583088,-0.0045073205,-0.02510993,-0.011603952,-0.027299656,-0.04328306,-0.043858465,-0.035323326,0.018476816,-0.003732125,-0.0059338394,0.019275988,-0.071094185,-0.019275988,-0.010948633,-0.0220571,-0.054887015,0.0008915743,-0.0015893498,0.026005,0.03041642,0.021146046,-0.013130368,-0.016159223,-0.0033025711,-0.01675061,-0.017118227,0.007835864,0.07160565,-0.03116764,0.03153526,-0.010397205,0.00077269773,0.0130025,0.025317714,-0.021369813,0.023671424,0.009645985,0.014824608,-0.018860418,0.02379929,-0.0023715377,-0.02896193,-0.0017491839,0.014337114,0.017773546,-0.0015284132,0.027123839,-0.003306567,-0.036825765,0.03107174,0.037273303,0.026724253,-0.015895497,0.065212294,-0.0109326495,0.018828452,0.024678377,-0.033629086,-0.02050671,-0.0055862,0.014185272,-0.03145534,0.01854075,-0.006529221,0.042260125,0.004870943,0.026788186,0.0149924345,-0.010644948,-0.009430209,-0.007979715,-0.0006553196,-0.006772968,0.01520821,-0.039159343,-0.02666032,0.0045352913,0.009725902,0.02103416,-0.024118958,-0.005742038,-0.013090409,0.0034963698,0.016231148,0.012283247,0.028945947,-0.013977488,-0.00783986,0.017405929,-0.0054303617,-0.048365783,-0.038743775,-0.0035383264,-0.012978525,-0.015384028,0.057987794,-0.010756832,0.00054743164,-0.005666117,-0.012187347,-0.011476085,0.0134580275,-0.010485114,-0.010852732,-0.029968886,-0.027139822,0.010173437,-0.0010279327,0.024566494,0.0294734,0.015392019,0.015807588,-0.009869752,-0.0062135486,-0.012171363,0.020618593,-0.022520619,0.011276293,0.005829947,0.009869752,-0.015687712,-0.0021058137,-0.022153,-0.015360053,-1.2611906e-05,-0.013529953,-0.006269491,-0.013042458,-0.023879208,0.039447043,0.016359014,0.030816006,-0.014752683,-0.02455051,-0.035227425,-0.018556733,-0.0038060483,-0.018652635,-0.0070566735,-0.021721447,-0.004299536,-0.0008131557,0.018316982,0.0007022709,0.03378892,-0.00086460233,0.013737737,-0.05050756,0.0061376276,0.051978033,-0.0010828756,0.0038280257,-0.015048376,0.015423986,-0.0514346,0.04871742,-0.011068508,-0.020970227,0.02549353,-0.05261737,0.01844485,0.034428254,-0.004599225,0.015839554,0.01732601,0.01576763,-0.037816737,-0.017757563,-0.019755488,-0.009685944,-0.023991091,0.0184928,0.0061975652,-0.017294044,0.053192772,-0.019339921,-0.15446363,-0.010149462,0.018860418,-0.01615123,-0.017421912,0.0013525956,-0.012075462,-0.006960773,0.014656782,0.0522977,0.006852885,-0.05613372,0.0016982368,-0.0046631587,0.004009837,-0.008878781,-0.0061176484,0.03257418,-0.0009625007,0.0020818384,-0.020586627,-0.021769399,-0.0064413124,-0.015280135,-0.01328221,0.004675146,-0.044433866,-0.0037381188,0.018460833,-0.029777084,0.046735477,0.022424718,-0.022440702,0.028466444,-0.04158882,-0.0065492005,0.031375423,-0.0296652,-0.0044154157,-0.03778477,-0.0074242917,0.0073563624,0.0022636498,0.030991822,0.03167911,-0.018029282,-0.0022876249,0.008559113,0.04631991,-0.011556002,-0.008359321,-0.011012566,0.017725596,-0.021289896,0.0025893117,-0.004195644,-0.002097822,-0.016878476,-0.004783034,-0.008663005,0.043155193,0.01788543,0.05060346,-0.026324669,0.04763055,0.01262689,-0.011036541,0.03022462,2.2336184e-05,-0.0013865604,-0.009981637,0.03359712,-0.012970533,0.013114384,-0.0062974617,0.043027326,-0.03666593,0.0079117855,0.008878781,0.007827872,-0.0013515967,-0.009518118,0.029920934,-0.025093947,-0.015839554,-0.00640535,-0.044721566,0.0068728644,-0.0052745235,-0.017773546,-0.009334309,-0.047886282,-0.017629696,0.007899798,-0.0034024674,-0.016367007,0.013553928,-0.013977488,-0.1198116,0.008279404,0.04820595,-0.006429325,0.0032426333,0.018508783,0.016183197,0.019595655,0.002743152,-0.02130588,0.026916055,-0.019707538,-0.015967421,-0.012003537,0.03271803,-0.041237187,0.007843856,-0.02125793,0.0051506525,-0.037273303,-0.008319362,0.0038879632,0.005486304,0.01619119,-0.009989629,-0.027187772,0.011643911,0.029825034,0.0068728644,-0.018364932,-0.030160686,0.009925694,-0.0257173,0.012834675,-0.028802097,0.02877013,-0.009981637,0.008766898,0.012570948,-0.0053824116,0.017581746,-0.02520583,0.023207905,-0.034588087,-0.004683138,0.005186615,0.021050144,-0.02586115,-0.008934723,0.03657003,0.01929197,0.012754757,-0.015919471,-0.022216933,-0.013969496,0.0029369507,-0.008123565,-0.02135383,0.043027326,0.019116152,-0.008303379,-0.003570293,0.022712419,-0.037529036,-0.0009899721,0.008079612,0.0048749386,0.023112005,-0.017773546,-0.0040617827,-0.016766593,0.020458758,0.030879939,0.024790261,0.007528184,-0.010157454,0.025429597,0.043858465,0.005242557,-0.015056368,0.04961249,-0.05645339,0.0025433593,0.02534968,-0.018157149,0.045744505,-0.008742923,-0.002926961,-0.006928806,0.036697898,0.02920168,-0.027970959,-0.01027733,-0.019515738,-0.015232185,-0.02093826,-0.012706807,0.023863224,0.03121559,-0.0046032206,0.0515305,0.028370544,-0.0028130794,0.009462176,-0.040725715,0.02496608,0.00360226,-0.019915324,0.0043914407,0.013969496,-0.006565184,-0.00047875295,-0.010565031,0.018364932,-0.015368044,0.031183623,0.061472178,-0.026852122,0.0026772204,-0.012978525,0.026740236,0.001047912,-0.03778477,-0.025141897,-0.025877133,0.020011224,0.0062135486,0.024182891,-0.016367007,-0.03359712,0.007140586,0.02816276,-0.008471205,0.0052825157,0.0027551395,0.004155685,-0.015408003,-0.002283629,-0.033565152,0.006529221,0.01248304,5.1446586e-05,-0.0129145915,-0.012890616,0.0027391561,-0.032925814,-0.020954244,-0.009510126,-0.03036847,0.017341994,-0.0056341505,-0.011228343,-0.0096699605,0.022840286,0.011092483,0.03150329,-0.0018680604,-0.036154464,-0.015591811,-0.023511589,0.023831258,0.03233443,0.013649828,0.010676915,0.013905562,-0.032925814,-0.006505246,-0.007012719,-0.0053864075,0.030528303,-0.0067609805,0.008830831,0.045520738,0.008067624,0.026036967,0.043027326,0.03519546,-0.0005394399,0.027091872,0.026372619,-0.029121764,0.022968153,-0.0149205085,0.019260004,0.0016233146,-0.029025864,0.02168948,0.028450461,-0.011715836,-0.0052065942,0.0014055407,0.00032291474,0.0014135324,0.029489383,-0.0078878105,-0.022216933,0.022264883,0.0061616027,-0.030544287,-0.01145211,0.0028010919,0.014672766,-0.011747803,-0.01295455,-0.02013909,0.028802097,-0.01037323,-0.010197412,-0.018364932,-0.007096632,-0.018556733,-0.02079441,-0.03848804,0.023207905,-0.02370339,0.020027207,0.005626159,0.036729865,-0.035930693,-0.05383211,-0.01619119,-0.023687407,-0.042579792,-0.006081686,-0.019835405,0.027938992,0.02055466,0.0014904526,0.023831258,0.004243594,-0.005122681,-0.015719678,-0.0051946067,0.015759638,0.016462907,-0.0062175444,0.009765861,0.011899645,0.0146967415,0.004323511,0.016734626,0.017341994,0.004890922,-0.024934113,-0.0077759265,0.0034584093,0.042132255,0.009765861,-0.003686173,-0.018141165,-0.012962542,0.025797216,0.044274032,0.0029089798,0.0261009,-0.01759773,0.02990495,0.04718301,0.0019689556,-0.0048749386,-0.014576865,0.0036442163,-0.007963732,-0.011516044,-0.015983405,-0.01445699,-0.018045265,-0.00010389213,0.023495605,0.03657003,0.009278366,0.02566935,0.00048624515,0.031247558,-0.01732601,-0.018412882,-0.019467788,0.0057340465,0.016766593,-0.0023195916,-0.023831258,-0.010477122,-0.004543283,0.017262077,0.010021595,-0.025845166,-0.027619325,-0.022600535,0.026356636,0.015591811,0.0061216443,0.017917397,-8.6535154e-05,0.017805513,-0.01727806,-0.0013236258,0.00017194648,0.0010329275,0.018956318,0.012091446,0.005694088,0.050187893,-0.00019342417,-0.034012686,0.021241946,0.0010818767,0.020203024,-0.032686062,0.0184928,0.024998046,-0.04491337,0.013961504,0.0065412084,0.017581746,-0.00039858615,0.0059578144,-0.018572716,-0.013418069,0.0059777936,-0.004483345,0.0021697474,0.015072351,0.020075157,0.039926548,0.0040997434,-0.022025133,0.021897266,0.01929197,0.01745388,-0.0034524156,0.04590434,-0.011883662,-0.0035083576,0.0037281292,-0.024374694,0.0141772805,-0.022440702,-0.008359321,-0.0012756755,-0.024262808,-0.02013909,0.019915324,0.012850658,0.021865299,0.021385796,-0.016510857,-0.024934113,0.0065132375,0.016702658,0.018237066,0.09711517,-0.016303074,0.009925694,0.019148119,0.006928806,0.028082844,-0.002791102,0.023335772,-0.019100169,-0.002095824,-0.008439238,0.00402582,0.005941831,0.0021997162,0.028850047,-0.015415994,-0.0065092416,-0.021002194,0.0038500028,-0.0032466291,0.00882284,0.0258132,-0.005318478,-0.03177501,0.020490725,-0.0036981604,0.013170326,-0.0007831869,0.030688139,0.022456685,0.034012686,-0.025653366,-0.0025633387,0.039542943,-0.020522693,0.0151682515,-0.011236334,-0.011683869,-0.013649828,-0.005941831,0.015392019,0.0072404826,0.0077999015,-7.4610034e-05,0.024870178,0.015567836,0.0010888695,-0.01060499,-0.033948753,-0.026979988,-0.03816837,0.028450461,0.016958393,0.01403343,0.0037840712,-0.018668618,-0.013026475,0.04347486,0.019563688,0.016462907,-0.039542943,0.026868105,-0.015455953,0.025461564,-0.03979868,-0.013961504,-0.011084491,0.013290201,-0.023032088,0.013753721,-0.021897266,0.0094222175,0.027347606,-0.0016353021,0.014888542,0.012235297,0.003812042,0.012714799,0.03685773,0.030096753,-0.022984136,0.0048229927,-0.020219008,0.014760675,-0.014281172,0.015056368,0.023383722,-0.0048789345,-0.026995972,-0.015040385,-0.042451926,0.0016802555,0.046575643,0.055206683,-0.019771472,-0.008894765,-0.010948633,0.01769363,-0.0074282875,0.004619204,-0.017949363,0.0121953385,-0.01764568,-0.011587969,-0.010820765,0.006365391,-0.05041166,0.0040378077,0.01548792,0.011939604,-0.0035662972,0.007995699,0.024854194,0.007971724,0.00020228997,0.017310027,0.031790994,0.014193264,-0.019851388,-0.049132988,0.013985479,0.015328086,0.018700585,0.0006613134,0.0021757411,0.0142012555,0.019052219,-0.030448386,0.0065771714,-0.008559113,-0.008199487,0.009302341,0.022872252,-0.014137322,-0.0046511707,0.028578328,-0.00999762,-0.023879208,-0.03121559,-0.0112043675,-0.009222425,0.029313564,0.024039041,0.0005754026,0.0018910366,-0.0445937,-0.0030808013,0.011548011,-0.00079117855,-0.006561188,-0.0020818384,0.013026475,0.018844435,0.018013299,-0.019707538,-0.026005,-0.0004730089,-0.015927464,-0.016542824,0.0013915552,0.008623047,-0.036314297,-0.008375305,-0.016271107,0.018380916,-0.011563994,-0.038871642,0.015128293,0.013953513,0.010229379,2.5551595e-05,0.011372193,-0.021817349,0.010461139,0.0099416785,-0.035706926,0.00026522463,0.018860418,-0.017805513,0.0293775,0.008087603,0.011236334,-0.0025653366,-0.030016836,-0.021833332,0.005809968,-0.00193599,0.004543283,-0.026436552,0.000105702755,-0.0028830068,-0.012107429,-0.019004269,0.027059905,0.023159955,0.028578328,-0.009182466,0.008782881,0.0002994391,0.04849365,-0.026692286,-0.0013675801,-0.015288127,-0.008383296,-0.012930575,0.021929232,-0.0059298435,-0.020474741,0.008295387,0.013242251,-0.011963579,-0.01600738,-0.007284437,0.024790261,0.020906294,-0.020282941,-0.016926426,0.014760675,0.0044513782,-0.022360783,0.009102549,0.008191495,-0.021673497,-0.022520619,0.009845777,0.004655167,0.030160686,-0.029841017,0.017821496,0.034588087,0.006285474,0.00044328975,0.013553928,0.02023499,-0.01403343,-0.015599803,-0.029169714,-0.017709613,0.027555391,0.0026472516,-0.02144973,0.035802826,-0.0009749877,0.009733894,-0.035706926,0.055654217,0.007068661,-0.0075601507,-0.017006343,0.0044473824,0.039319176,0.011548011,0.00013848122,-0.0149444835,-0.0067849555,-0.009430209,-0.030768055,-0.013977488,0.0012317211,0.035930693,-0.037944604,-0.008067624,0.0034064632,-0.017965347,-0.029025864,0.037944604,-0.03314958,0.017981332,0.0003086795,0.0039439052,0.005781997,-0.0054663247,0.0043354984,-0.0137297455,-0.013018483,0.007556155,0.027347606,0.0017132212,0.005510279,-0.048333816,-0.020714493,0.005718063,-0.026404586,-0.0069647687,0.0024294776,-0.0039918553,-0.013138359,-0.028178744,0.016910443,-0.000726246,-0.008155532,0.02013909,-0.0017961352,0.0076720347,-0.02549353,0.009286358,-0.008103587,0.0036142475,-0.015032393,0.0072165076,-0.009142508,-0.0022376766,0.018668618,-0.023159955,0.01450494,0.04178062,-0.0040158303,0.024039041,-0.021193996,0.03051232,0.03816837,-0.019323938,0.013114384,0.016414957,0.0139295375,0.034588087,-0.00079667283,-0.0027970958,-0.027875058,-0.0016173208,-0.0048789345,0.021241946,0.021833332,-0.008830831,0.012331197,-0.00795574,-0.01854075,0.0053424533,0.034811858,-0.020410808,0.04078965,0.007276445,0.043858465,-0.039063442,-0.0046631587,-0.035706926,-0.025877133,0.012323205,0.0033365358,-0.020378841,0.0028530378,0.01323426,-0.00049348763,-0.02144973,0.008027665,0.01662274,0.003492374,-0.016926426,-0.0017711611,-0.012586932,0.007440275,0.040725715,0.024566494,0.0026152846,-0.041812588,0.004479349,0.00039159344,-0.018221082,0.014001463,0.012714799,-0.022616519,-0.016862493,0.0070886402,0.009374267,0.0027511436,0.044561733,-0.0061176484,0.004077766,0.0021697474,-0.031759027,-0.029585283,0.0057899887,0.009478159,-0.0068768603,-0.0052465526,-0.013226268,-0.06553196,0.0047630547,0.0052305693,-0.040725715,0.016319057,0.012515007,0.011651902,0.017661663,0.039127376,0.024518544,-0.018141165,0.013298193,0.01929197]	2025-06-21 20:56:23.484783-04	0
content	2c57be63-ce62-4569-911a-c2c8950f8194	[0.030938921,0.0038913223,0.061549287,0.03742788,0.038386166,-0.03373164,-0.025668353,0.05634717,-0.016619403,0.03493634,0.04336925,-0.07381534,-0.052048575,-0.03165079,0.0005364686,-0.010787553,-0.04974869,-0.00907633,-0.002710578,-0.013751392,-0.01819373,0.023546437,0.008624567,0.057442352,-0.008823069,-0.05618289,0.03748264,0.005996127,-0.018330626,-0.008063286,0.029706841,-0.01939843,-0.03427923,0.012142843,0.0003858809,0.019973401,0.0058044703,-0.04189075,0.025668353,0.025079692,-0.018248487,-0.016085502,-0.003528543,0.056730483,-0.06773707,-0.013381768,-0.0017155017,-0.028940212,-0.008939432,0.047996398,-0.04783212,-0.004219877,-0.019672226,-0.03345784,-0.030500848,0.035374414,0.0031640523,0.017358651,-0.012690434,0.010109909,0.023464298,-0.022506012,-0.0023477988,-0.011910116,-0.038906377,0.0074130204,-0.019288912,0.008179649,-0.017208064,-0.014018343,0.025928458,0.008138579,-0.021369759,-0.011465197,0.020219818,-0.017016407,-5.5775192e-05,0.05254141,-0.014045723,0.014305829,0.021931041,0.009863492,-0.021410828,-0.03896114,-0.027845029,0.0010267341,-0.018399075,-0.028556898,-0.09057164,-0.005571744,-0.016523575,0.020123988,-0.02915925,0.007673126,0.011711614,0.03751002,0.02967946,0.043971602,0.04802378,0.05314376,-0.017728277,-0.024518412,0.0297616,0.033978056,0.027475405,-0.019973401,0.042520482,-0.03819451,0.0027978504,-0.020616822,-0.103385285,-0.0311032,-0.060563624,0.027571233,-0.039700385,-0.042191926,-0.011458353,0.014415347,0.014086792,-0.01165001,-0.02844738,0.017687207,0.011643165,0.0036928204,0.041288402,-0.037592158,0.021027515,-0.015058767,-0.033348326,-0.052185472,0.021041205,0.042465724,0.03816713,-0.018330626,-0.019726984,-0.025969528,0.013676099,-0.008001681,-0.038933758,-0.014032033,0.017180685,-0.018029451,-0.032444797,0.007050241,0.0020534683,-0.048598748,-0.007282967,-0.0029107912,-0.0044491813,0.01815266,-0.008467134,0.018494904,-0.039015897,0.02643498,-0.034032814,-0.0024436272,0.0073445714,0.060618382,-0.006198052,-0.06160405,-0.039207555,0.024901725,-0.033266187,0.0058010477,-0.02135607,0.032855492,-0.02334109,-0.06023507,-0.061713565,-0.06258971,-0.037592158,-0.041206263,-0.0060714213,0.019685915,0.018426456,-0.006033774,-0.019521639,4.941158e-05,0.0075430735,-0.06494436,-0.026037978,-0.014648073,-0.05297948,-0.011944341,-0.042301446,-0.008734085,-0.018467525,0.014360588,-0.04774998,0.0008355049,0.01886453,0.046791695,0.059851754,0.008241253,0.053225897,-0.032526936,0.056620963,-0.013676099,0.033375703,-0.06319206,0.02643498,0.0056812624,-0.0309663,-0.019809123,0.007810024,-0.04774998,0.033676878,0.0082549425,-0.045395337,-0.017700896,0.039125416,-0.016687851,0.05623765,0.008152269,-0.048160676,-0.019603778,-0.056511447,-0.0245321,0.008925742,0.037154086,-0.01486711,0.053937767,-0.011150332,0.026968883,-0.020206127,-0.015647428,0.009158469,-0.0077963346,0.037318364,-0.012882091,0.030117534,-0.01134199,-0.002455606,-0.04082295,0.008261788,-0.051993817,0.01739972,-0.014949249,0.023409538,0.026393913,0.035757728,-0.0047195544,-0.002763626,0.035319652,-0.008686171,0.009404885,0.016400367,-0.032882873,0.036250558,0.034005433,0.022820877,-0.0036380612,0.056675725,-0.0065026493,0.013559735,-0.028994972,0.021931041,-0.011848512,-0.020863237,0.00012641663,-0.026120117,0.032444797,-0.05360921,-0.0106301205,0.012211291,0.037674297,-0.023053603,0.025175521,0.0030562452,-0.038632583,0.01618133,0.015702188,0.012834176,-0.014976628,-0.038742103,-0.01423738,0.0032872604,0.025120761,-0.0014049145,0.054156803,-0.056730483,9.507986e-05,0.042547863,-0.0126972785,-0.0020551796,0.02644867,-0.033895917,-0.0424931,-0.05815422,-0.0735963,0.026654018,0.006639547,0.00015892989,-0.013669253,0.032444797,-0.014579625,0.06330158,0.082576804,-0.021068584,0.0082823215,0.033320945,-0.020781098,-0.00019368912,-0.032554317,0.00059764483,0.033129286,-0.030747265,-0.01948057,0.03603152,0.001683844,-0.0021167835,0.012834176,0.0323079,-0.017646138,-0.07173449,-0.015674807,0.050159384,-0.0414253,0.02907711,-0.00903526,-0.022410184,0.007912697,-0.0034275807,0.017919933,-0.02072634,-0.052404508,0.022875637,0.017235443,-0.021684624,-0.07469148,-0.009945631,0.026845675,-0.02981636,0.0050549544,-0.033184048,-0.02595584,0.029268768,-0.006677194,0.0030836249,-0.01605812,-0.057332832,-0.0309663,-0.03942659,0.009473333,-0.0076457467,0.002020955,-0.044847745,-0.026462361,0.027270058,0.043643046,-0.004110359,-0.010246807,0.0019097255,0.035264894,-0.066368096,0.016592024,-0.017632447,-0.006047464,0.010493223,-0.01624978,-0.046463143,-0.03422447,0.04471085,0.061658807,0.013073748,-0.000553153,-0.047667842,-0.017372342,-0.008042751,-0.03871472,-0.011684234,-0.018207418,0.026736157,0.0006203185,-0.052075956,0.028611658,-0.020343026,0.012081238,0.021424519,0.0504058,0.009459644,0.008987346,0.014059412,-0.023765473,-0.00218181,0.055854335,-0.0009317612,-0.041863374,-0.057989944,0.035429172,0.054266322,-0.020493614,-0.028173584,0.031513892,0.02460055,-0.0015289782,-0.0023409538,0.019672226,0.06751803,0.039755147,0.0022160346,-0.03896114,-0.021219172,-0.018303247,-0.0065266066,0.006047464,0.024039268,0.030719886,0.020219818,0.014716523,0.009856648,-0.036442216,0.03748264,0.008583497,-0.031924587,0.002144163,-0.030035395,0.01419631,-0.009582852,0.052760445,0.020849548,-0.041288402,-0.0037954939,-0.03228052,0.02253339,0.031349614,0.0065334514,-0.0040247976,0.023532746,-0.018549664,-0.065930024,0.02325895,0.008569808,-0.066368096,-0.013546046,0.0008872694,0.04139792,0.037099328,0.024805896,-0.0017180684,-0.0052226544,-0.031924587,-0.022423873,-0.0031520738,-0.0075430735,-0.047503565,-0.052568786,0.012464552,-0.03249956,-0.05503295,-0.005540942,-0.03219838,0.06357538,0.01690689,-0.032718595,-0.025558835,0.028830694,-0.038906377,-0.0045586997,0.024299374,0.03102106,-0.019603778,-0.032773353,0.042109787,-0.012204446,0.0010849157,0.003918702,-0.012177067,-0.006913343,-0.0029655504,-0.038906377,-0.0013056636,-0.016071811,-0.0137308575,-0.020534683,-0.0075772977,0.01483973,-0.022232216,-0.0123344995,0.028721176,-0.023354778,0.007371951,-0.0010917606,0.011492577,0.04074081,0.00091208215,-0.034580406,0.0023323977,0.031157957,0.012567226,-0.033895917,-0.020397784,0.09117399,-0.014730212,0.0309663,-0.0013441661,-0.015250424,-0.017646138,-0.033403084,-0.023655955,0.015442081,-0.0075909877,-0.059249405,0.031623412,-0.0056504603,-0.0067559103,0.05377349,0.016605712,-0.025736801,0.035182755,-0.0032290788,-0.0009839536,0.024135096,0.034826823,0.0052911034,0.04473823,0.038933758,0.044053737,0.0035696123,0.0071734493,0.03797547,-0.018590733,-0.012074393,-0.003054534,0.00056983746,-0.03430661,-0.03165079,0.021725694,-0.015866464,-0.0031041596,-0.0028645883,0.0068483166,0.011472043,0.0028183851,-0.052294992,-0.005540942,0.013162731,0.0058694966,-0.028967593,0.033266187,0.028611658,0.024107717,0.06401345,0.034498267,-0.013669253,-0.0018601,-0.009055795,-0.02981636,-0.0016701542,0.017276512,0.061001696,0.010370014,0.01615395,-0.023655955,0.012553536,0.01685213,0.02257446,-0.030528229,0.008686171,-0.01616764,0.014812351,-0.008234408,0.0071597593,0.013977274,-0.0041274712,-0.009069485,0.015318873,0.0072282082,0.02523028,-0.0053287502,-0.026147496,-0.02647605,0.033129286,-0.037865955,0.021520346,0.003949504,0.02521659,-0.0032667257,0.03299239,0.033978056,-0.040987227,-0.014470106,-0.01325856,0.042465724,0.00015112243,0.008864138,0.008487669,0.026695088,0.012464552,0.036168423,0.012560381,0.012170222,-0.00776211,-0.03945397,0.030637747,0.0019918643,0.0065471414,-0.013819842,-0.020370405,0.029515184,0.00024983863,-0.011526802,0.00085347274,-0.0070228614,-0.029898498,-0.03742788,0.010287876,-0.005280836,0.029405665,-0.034717303,-0.022464942,-0.024052959,-0.0018669448,0.018166348,-0.0006870563,0.0077210404,0.0040555997,0.013559735,0.050871253,-0.016455125,-0.02460055,-0.040275358,-0.013840376,-0.0055169845,0.010411084,-0.0008872694,0.008604032,-0.010828623,0.002686621,0.011499423,0.013231181,0.030500848,0.004586079,0.010534292,0.021889972,-0.02139714,-0.01000039,-0.005232922,0.0045518545,-0.04588817,-0.00843291,0.02981636,0.01805683,-0.015140906,0.025175521,-0.0046476834,0.005872919,-0.017878864,-0.002455606,-0.0013039523,-0.039727766,-0.036004145,-0.002281061,0.030473469,0.023327399,-0.024819586,0.0007080187,-0.022259597,0.02461424,0.023806542,-0.037701678,-0.023368469,-0.030090155,-0.018440144,-0.013053213,0.025024934,0.028118825,0.033211425,0.032526936,0.004171963,-0.03433399,0.0011704769,0.0040008407,0.019015117,-0.0068620066,-0.033348326,-0.00025689745,-0.029542563,0.027584923,-0.006906498,-0.0040555997,0.01872763,-0.038523063,0.010773864,0.027612302,2.7566743e-05,0.037920713,0.003819451,0.020137679,-0.058537535,-0.017618757,-0.0033043725,-0.018358007,0.012710968,-0.03165079,0.022971464,-0.009938787,0.019521639,-0.06417773,-0.089585975,-0.01426476,0.022492323,0.0024846967,-0.03690767,0.010370014,-0.004011108,0.010287876,0.006974947,0.037756436,-0.011273541,-0.019781744,0.011547336,-0.021178102,-0.0017694051,-0.023368469,-0.011218782,0.029378286,0.017673517,-0.017961003,-0.023519056,-0.026298083,-0.0044765607,-0.004538165,0.009966166,-0.010205737,-0.052842584,-0.013874601,0.015017698,-0.02253339,0.008604032,0.012854711,-0.03211624,-0.0137308575,-0.016071811,0.0017676939,0.007296657,-0.029871117,-0.0070707756,-0.041151505,0.015140906,0.028994972,-0.020808479,-0.00021753929,0.032855492,-0.0068517393,-0.0144564165,0.0075772977,0.024846965,0.030199673,-0.023436917,-0.028994972,0.013511821,0.004846185,-0.008172804,0.0071597593,-0.013107972,-0.013409148,0.023477986,-0.016523575,0.0031349615,-0.005828427,0.02516183,0.019521639,0.02272505,0.017783035,0.001428016,0.027297437,0.03241742,-0.013600805,0.014675453,-0.00096855254,0.0049899276,0.026818296,-0.009856648,0.021410828,-0.007940077,0.025504075,-0.006841472,0.03444351,-0.0037989162,-0.0031572075,0.004469716,-0.011855356,-0.018453835,-0.011061349,-0.03504586,0.004353353,0.007673126,-0.007098155,0.008063286,-0.052212853,0.015578979,-0.008179649,-0.014319519,-0.04271214,0.0064478903,0.014784971,-0.08290536,0.018563353,0.03945397,-0.018440144,0.012156532,-0.0023238417,0.025312418,0.028036686,0.024805896,-0.033430465,0.0297616,-0.018399075,-0.010595896,0.012245515,0.015414702,-0.02258815,-0.025723113,-0.035237513,-0.0023922906,-0.005503295,-0.024655309,0.004031643,0.008816224,0.019617466,-0.0075430735,-0.011033969,0.0026968883,0.048680887,-0.039207555,0.0045586997,-0.0067661777,-0.0033334636,-0.016277159,0.034580406,0.015469461,0.008686171,-0.001981597,0.02583263,-0.002725979,-0.016386677,-0.0041206265,0.003651751,0.04462871,-0.016920578,-0.006163827,-0.02844738,0.02586001,-0.010157823,0.016879508,0.0029604167,0.024641618,0.005321905,-0.020808479,-0.030062776,-0.018316938,0.018453835,-0.025791561,-0.021588797,0.047585703,0.013402303,0.0015101548,0.0068483166,-0.027297437,0.003997418,-0.001227803,0.007556763,0.018207418,0.043040693,-0.047613084,-0.019904952,0.00647527,0.0022981733,-0.02850214,0.029214008,0.02072634,-0.019768054,0.036250558,0.021424519,0.012286585,-0.01672892,0.043506145,-0.04194551,-0.04202765,0.008111199,-0.042410966,0.018344317,-0.007050241,-0.03176031,0.016290847,0.003963194,0.022998845,-0.015359943,0.010589051,-0.011869047,-0.012238671,0.010370014,0.004883832,0.007974301,0.0036346389,-0.0238613,0.015756946,-0.014155241,-0.020356715,-0.0054964502,-0.02781765,0.0077347304,-0.0026729312,-0.005571744,0.007371951,0.02717423,0.020315645,0.032855492,0.0021954998,0.02658557,0.041835994,0.030911542,0.011807443,-0.03156865,-0.020740028,0.014333208,0.0077758,-0.0106027415,-0.050104626,0.023738094,0.017208064,-0.022286976,-0.028803315,0.0056162355,0.015401012,-0.025531456,0.049666554,-0.0018070521,-0.01392936,0.007946922,-0.022560772,-0.01033579,0.027612302,-0.030500848,0.010109909,-0.020411475,0.0046819076,0.0011661989,-0.04974869,-0.0013039523,0.003054534,-0.009021571,-0.05760663,-0.013162731,0.004332818,0.013107972,0.010431618,-0.0137582375,0.007193984,0.037044566,-0.01813897,0.033868536,0.012971074,-0.037592158,-0.015620048,0.034416128,0.03805761,-0.0005711209,-0.010897071,0.006009817,-0.016619403,-0.029296147,-0.008487669,-0.009377505,0.010020925,0.0070228614,-0.0099593215,-0.03488158,0.035757728,0.02844738,0.010458998,0.054594874,0.014292139,0.024778517,0.012252361,0.032088865,-0.000802136,0.031924587,0.008877828,0.03444351,0.01325856,0.006016662,-0.011882736,0.0034173133,-0.0014596736,-0.02069896,0.018700251,-0.012498776,0.008624567,0.038358785,-0.03562083,-0.034607787,-0.020370405,0.01813897,-0.028091446,-0.041124124,-0.052212853,0.03559345,0.0032290788,0.019507948,-0.01624978,0.010431618,0.00025283327,-0.04640838,-0.002142452,-0.0073582614,-0.032006726,0.011253006,-0.010589051,-0.021191793,-0.010568516,0.040330116,0.024066648,0.028967593,-0.035374414,-0.02009661,-0.04139792,-0.013546046,-0.008973656,-0.012286585,-0.035812486,0.025969528,-0.0066019003,-0.028666416,0.0060200845,0.004760624,0.029871117,-0.011143488,0.013689788,0.017878864,0.015332563,0.0008812801,0.019699605,0.014853421,0.015045078,0.014716523,0.006369174,0.030500848,0.019097256,-0.025079692,0.0036141041,-0.013149042,0.038304027,0.014114172,-0.006338372,-0.04482037,-0.022478633,0.006249388,0.05349969,0.023847612,0.032965012,-0.0046339934,0.034005433,0.004637416,-0.017344961,-0.004928324,0.015811706,0.010458998,-0.03422447,0.019453188,-0.009103709,-0.00745409,-0.025011243,-0.0060679987,0.009110554,0.04011108,0.0010874826,0.03679815,-0.0064786924,0.0046682176,-0.026763536,-0.0003565762,-0.03477206,0.010315255,-0.008542428,-0.03211624,-0.018974047,-0.016468816,0.0021681201,0.046955973,0.0050857565,0.013949894,-0.0061227577,-0.0053937766,-0.009398039,-0.0059208334,0.0044354913,0.036551736,-0.0032581696,0.015387322,-0.021164414,0.0068038246,0.008384995,-0.021000136,0.01609919,0.009158469,0.0060508866,0.035976764,-0.00258737,-0.0069338777,0.02718792,-0.031459134,-0.04640838,-0.057825666,0.019754365,0.026257014,-0.037811194,0.02724268,-0.009671835,-0.00971975,0.010910762,-0.020192437,-0.021670936,0.0077141956,0.007981147,-0.030254433,0.01874132,0.026284393,0.017865174,0.035894625,0.014511175,-0.040603913,0.012218136,-0.01811159,0.0010207448,0.020343026,0.030911542,0.0109655205,-0.017810415,-0.00013197811,0.0028200964,0.037592158,-0.015496841,-0.010910762,0.004004263,-0.010356325,-0.0073445714,-0.015346252,0.019083565,0.007371951,0.049310617,-0.011485732,-0.002387157,-0.034416128,0.0037202,0.014565934,0.06888702,-0.03159603,0.0021219172,0.019562708,-0.01033579,-0.013881445,-0.0018703673,-0.0054793376,-0.0037373123,-0.022656599,-0.02785872,0.022547081,0.0027157117,0.00402822,-0.011184557,-0.026558189,0.011047659,0.014976628,0.0025445893,-0.016482506,-0.017002717,0.01886453,-0.028693797,-0.013676099,0.0077963346,0.005893454,0.04703811,0.0030511115,0.028639037,0.0034874736,0.021931041,-0.0048667197,0.014661763,0.043040693,0.027009953,0.016126571,0.0026695088,0.0016804215,-8.262001e-05,0.0022776385,0.017769346,0.028748555,-0.009014726,-0.0023580662,-0.0075362283,0.0005672706,-0.01749555,-0.031404376,-0.023655955,0.006523184,-0.035018478,-0.00077732326,0.018618112,-0.002541167,-0.018221108,-0.0031058707,-0.032143623,0.0454501,0.017632447,0.008398685,-0.030062776,0.04917372,-0.03939921,0.0060029724,-0.024463652,-0.019685915,-0.027324818,0.019371051,0.010096218,-0.011218782,-0.010212583,-0.0053458624,0.042903796,-0.0008675903,0.02658557,0.042191926,-0.024094027,0.036579113,0.01618133,0.014073103,-0.045504857,0.021137033,0.014319519,0.0026010599,-0.003092181,-0.007378796,0.01875501,0.0133680785,-0.037701678,0.006591633,-0.030747265,0.020917997,0.030008016,0.024860656,0.0042780587,0.024723757,-0.03107582,0.02910449,0.016592024,0.0032787044,-0.003963194,0.0016248068,-0.03496372,-0.026640328,0.010171513,-0.0116363205,-0.028064067,0.018330626,0.023628574,0.011773218,-0.017947312,0.021862593,0.014210001,0.0068996535,0.017098546,-0.0010934719,-0.0036483286,-0.011294075,-0.0053458624,-0.035976764,0.018207418,-0.013094283,0.024477342,0.0049385913,-0.011923806,0.006944145,0.0007204251,-0.037756436,0.034087572,-0.03679815,-0.01738603,0.02397082,0.0252029,0.012238671,0.005948213,0.02191735,0.0052397666,-0.020917997,-0.02143821,0.015496841,0.007946922,0.017824104,0.027968237,0.007885318,0.0020123988,-0.04076819,-0.0043259733,0.0059995498,-0.030090155,-0.006677194,-0.008090665,0.021602485,0.015346252,0.03808499,-0.024737448,-0.027940858,0.019535327,-0.02783134,0.005558054,-0.027694441,0.00027336797,-0.017112235,-0.026311774,0.0053253276,0.021629866,-0.024874344,0.015250424,0.011773218,0.006451313,-0.0027550699,0.0010806377,-0.018207418,0.009747129,-0.007248743,0.0032975278,-0.04082295,-0.03422447,0.015168286,-0.023628574,0.025421936,-0.0043670423,-0.009507558,0.008706706,-0.038577825,-0.027543854,0.021232862,-0.011205092,0.0075430735,-0.033841155,-0.022369115,0.0015418124,-0.0031794533,-0.028091446,-0.010835468,0.006485537,0.028803315,-0.007570453,-0.016920578,0.034607787,-0.015195665,-0.023628574,0.004753779,-0.02779027,-0.011595251,-0.018946666,0.039262313,0.044272777,-0.0030494004,-0.004462871,0.054019906,-0.01813897,-0.013717168,-0.002296462,0.006269923,0.0036688633,-0.005253456,-0.013279094,-0.013860911,0.0030357107,-0.024422582,0.014305829,0.012375569,0.008932587,-0.022985155,0.0180979,0.0013484441,0.008384995,0.008829913,0.02852952,0.0061193355,0.0010891937,0.0055854334,-0.00876831,0.022382803,-0.024367822,0.024313064,-0.01672892,-0.009801889,0.013559735,0.010808088,-0.023751782,0.029652081,0.00025347498,0.010664345,-0.021191793,0.051939055,0.029350907,0.0013424549,-0.028420001,0.0010216004,0.026640328,0.0061398703,-0.015893845,-0.0010113331,0.0014596736,-0.016071811,-0.03102106,-0.0065437187,-0.030582987,0.012471397,-0.034005433,-0.005777091,0.009528093,0.0032633033,-0.022410184,0.022177458,-0.03679815,0.021164414,0.009952476,-0.026968883,0.014593314,0.020753719,0.013943049,-0.03868734,-0.020178748,0.006437623,0.008275477,0.022560772,-0.0061432924,-0.021465588,-0.055991232,0.012375569,0.011951185,-0.009856648,0.009644456,-0.014360588,-0.029953256,0.00483934,0.0039323918,-0.0020277998,-0.0020089764,0.04197289,0.019973401,0.02591477,-0.004148006,-0.0066874614,-0.01327225,0.033375703,0.003980306,-0.0015349676,0.014784971,-0.0008731518,0.015113526,-0.006523184,0.061713565,0.038002852,-0.022150077,0.018330626,-0.005044687,-0.0040692897,0.02528504,0.0043944223,0.02973422,-0.0063041477,0.0039871507,0.024888035,-0.0025514343,0.0026763536,-0.005318483,-0.023094673,0.016277159,0.02006923,0.010301566,-0.0007071631,-0.0049899276,-0.024997553,-0.02653081,-0.012745193,0.03507324,-0.03156865,0.033895917,-0.0076799714,0.029405665,-0.025449317,-0.034607787,-0.016263468,-0.024066648,0.010876536,0.0053390176,-0.008850448,-0.020219818,0.024655309,0.0023255527,-0.025120761,0.023368469,0.028173584,0.04000156,0.011485732,-0.01745448,-0.0060679987,0.01395674,0.014552245,0.007892163,0.049310617,-0.028639037,0.0077963346,0.042465724,-0.011786908,0.012498776,-0.0014648073,-0.037948094,-0.007953767,-0.006523184,0.005318483,0.0025463006,0.05358183,-0.010664345,0.0043601976,-0.008193338,-0.028091446,0.00075208273,-0.003405335,0.018180039,-0.020192437,-0.018905597,-0.035867244,-0.031294856,0.033868536,0.001921704,-0.014771282,0.022601841,-0.02577787,0.014100482,-0.012382413,0.010719105,0.0060679987,-0.00027828774,-0.0016675873,0.01609919]	2025-06-22 10:36:59.578249-04	0
content	35059838-9019-4ac4-900d-f9cdab29ee11	[0.020767972,-0.007878803,0.07019524,0.056416735,0.022759592,0.007860013,-0.01577013,0.04461732,0.0075719175,0.037151873,0.04531877,-0.04544403,-0.04752333,-0.037327234,-0.025602976,0.01896424,-0.011855781,-0.011454952,0.037302185,-0.018450677,-0.01405408,0.041936774,-0.04419144,0.060475133,-0.01460522,-0.030037152,0.01350294,0.003086073,-0.031415,0.012200244,0.045594342,-0.015732553,-0.06523498,0.014317124,0.0010232109,-0.008586517,-0.029511062,-0.015469508,0.033945236,0.004499936,0.019565484,-0.036124747,0.038554776,0.020417247,-0.021456897,-0.0320914,-0.013001903,-0.051957507,-0.026504843,0.046846934,-0.03221666,-0.0036293848,-0.012751385,0.013553043,-0.05406186,0.0026241797,0.012181455,0.012438237,0.03930633,0.03151521,0.075355925,-0.016383901,-0.028183315,0.022333711,-0.028007952,0.03574897,-0.008924716,0.041435737,-0.010960178,-0.004362151,0.018312892,0.0027118612,0.0008400194,0.0014381319,-0.0024018448,0.0062379073,-0.024901524,0.06748965,-0.008768142,-0.014655324,-0.04612043,-0.0033005793,0.004662773,-0.025264777,-0.017799329,-0.010114679,-0.013114636,-0.027131138,-0.030638395,0.06453353,-0.022408867,-0.012074985,-0.037627857,0.0043464936,0.0006286445,-0.009212812,0.05812026,0.04474258,0.05290948,0.038529724,-0.024225125,-0.02108112,0.033794925,0.062278863,0.025302354,0.0066011585,0.03529804,-0.00057775795,0.030888913,-0.013365154,-0.091088474,0.017536284,-0.042362653,0.030513136,-0.05446269,-0.034295965,-0.07255012,0.022534126,0.028033005,-0.014066606,-0.04486784,0.0050385506,0.003441496,0.034220807,0.002658626,-0.051356263,0.0021466292,-0.019014344,-0.06353146,-0.042187292,-0.0021434978,0.06633726,0.013239895,-0.034972362,-0.0036888828,-0.06733933,-0.018425625,-0.0060312296,0.016496634,-0.014029028,0.02743176,0.015945494,-0.017035248,0.0086616725,-0.03697651,-0.025114466,-0.018851506,-0.00022429222,0.01054056,0.04146079,0.027231345,-0.01561982,-0.031139432,0.031339847,0.005721213,-0.020329565,-0.0010169479,0.017511234,0.0040208194,-0.02893487,-0.041786462,0.036876302,-0.025953703,-0.018851506,0.022722015,-0.016947567,0.023285681,-0.045093305,-0.05912233,0.0069706733,-0.024926577,-0.04308916,0.0031815832,0.013490413,0.0013457533,-0.027907746,-0.023185475,0.016095804,0.041786462,-0.031740677,-0.03712682,-0.012475815,-0.03164047,-0.0300121,-0.0067264177,0.009087553,-0.012306714,-0.010903811,-0.031339847,-0.023060216,-0.0020918283,-0.004722271,0.061878033,0.06753975,0.04008294,-0.006078202,0.008649146,-0.0049352115,0.05280927,-0.018325418,0.012576021,-0.031715624,0.013891243,-0.027757434,-0.030362826,0.017573863,0.019214759,0.025728235,-0.029936943,0.029711477,0.027055983,-0.012839066,0.008893401,0.09078785,-0.034546483,-0.017699122,-0.050529554,-0.011855781,0.027106086,0.06929338,-0.005589691,0.049978413,0.00014639666,-0.009212812,-0.037903428,0.009043713,0.0032222923,-0.010659556,0.0020119755,-0.007308873,0.02565308,-0.008949769,-0.019302439,-0.061928138,-0.011780626,-0.02095586,0.046220638,-0.026630102,-0.008373576,0.014555116,0.0034728108,0.022847274,-0.0005554462,0.008467521,-0.032943163,0.011880833,0.036901355,-0.03314358,0.011974777,0.02795785,0.014467435,-0.033243787,0.05852109,-0.009845371,-0.013628199,-0.0017598915,0.014116709,-0.03712682,-0.046521258,-0.012193981,-0.016960092,0.032692645,-0.029936943,-0.041385632,0.026078962,-0.007139773,-0.000589501,-0.0013950741,0.0017301424,-0.055464763,0.05842088,0.0002777231,0.016909989,-0.009031187,-0.066938505,0.019941261,0.0025881678,0.011486267,0.006820362,0.06318073,-0.042813588,0.01204367,0.011235748,-0.0052420967,0.0001299564,0.028759507,-0.029135285,-0.0014835384,-0.029686425,-0.04243781,0.03246718,-0.017761752,0.014980998,-0.005533324,0.021206379,0.019728322,0.065435395,0.05471321,-0.046320844,0.03289306,0.043640297,-0.01577013,0.0008478481,-0.043339677,-0.02114375,0.019790951,-0.08392365,-0.029636322,0.01820016,0.013966398,-0.01500605,-0.009150183,0.014692902,-0.05115585,-0.03043798,-0.006256696,0.036876302,0.0034195755,0.0076971767,-0.03847962,-0.027481863,0.007177351,-0.012682492,-0.01583276,-0.0110791745,-0.0313649,0.038604878,0.024262702,-0.030888913,-0.04308916,-0.0010388683,0.023172949,-0.001714485,-0.027657228,-0.047974266,0.038454566,0.020830601,-0.021231432,-0.009983157,-0.016358849,-0.0024237651,0.003735855,-0.02245897,0.035423297,-0.02491405,0.0012674663,-0.049477376,-0.019440224,0.017097877,0.052759167,-0.000640779,-0.046070326,0.02059261,-0.0029201047,-0.034621637,0.04176141,0.006381955,-0.0012478946,-0.00046893905,-0.015907915,-0.034872156,-0.02878456,0.01911455,0.0382291,-0.03492226,-0.007014514,-0.09078785,0.0011516016,0.037352286,-0.023461044,-0.009951842,-0.025076889,-0.010340145,-0.041711308,4.205479e-05,-0.00035366145,-0.05416207,0.041736357,0.054362483,0.023911977,-0.014241968,0.011862044,-0.0009770216,-0.0004313613,-0.01896424,0.056416735,0.035723917,-0.03998273,-0.035774022,-0.045193512,0.06593643,0.018488254,-0.021669839,0.06979442,-0.007327662,-0.008229528,0.011285852,0.008786932,0.091739826,0.0225216,0.0057619223,-0.0009997248,0.02451322,-0.042237394,-0.009563538,-0.0028308574,-0.016095804,0.0030829415,-0.0048569245,0.027106086,0.016797256,-0.017348396,0.023836821,-0.008047902,0.0067577325,0.027632175,-0.028483937,0.0027416102,-0.010383986,0.03903076,0.033343993,-0.00015109389,-0.016396426,-0.027356604,0.013289999,0.027807537,-0.0012244085,-0.01923981,0.046596415,-0.034721844,-0.022070667,-0.00082827633,0.005846472,-0.031189535,-0.023573777,0.051907405,0.013026955,0.025264777,0.03835436,-0.00021313631,0.011204434,-0.012306714,-0.007001988,-0.011987303,-0.013841139,-0.018713722,-0.045519184,0.054512795,0.006068807,-0.009181498,-0.010358934,-0.015507086,0.012770173,-0.007841225,-0.03645042,-0.016484108,0.047097452,-0.0046596415,-0.035247933,-0.004158605,0.023423467,-0.019289913,-0.013690828,0.0586714,-0.0012400659,0.004205577,0.003350683,0.027106086,-0.05280927,0.0043402305,-0.008912191,-0.02163226,-0.021932881,0.011035333,0.01344031,-0.003219161,0.0023533069,-0.06603664,0.010139731,-0.03509762,-0.019014344,0.016308745,-0.06237907,-0.0037452495,0.03632516,-0.021719942,-0.014066606,0.017686596,-0.01610833,0.021782571,-0.005661715,-0.040984802,0.063581556,-0.012394396,0.05842088,-0.024187548,-0.02237129,0.004337099,-0.023185475,0.037427444,0.028458886,0.012219033,-0.026579998,0.018337945,-0.038805295,0.011467478,0.023736615,-0.0076783877,-0.008498835,0.017147982,-0.017699122,-0.038930554,-0.013866191,0.008004062,0.0148056345,0.061777826,0.020818075,0.02451322,0.011899622,-0.017799329,0.0038016161,-0.020567557,0.010145994,0.00958859,-0.012056196,0.008054165,0.00055074895,0.008398628,0.0024409883,-0.022321185,0.04642105,0.019214759,-0.021243956,0.015369302,-0.03424586,0.00042509835,0.0038579828,-0.00780991,-0.015532138,0.020855654,0.010866234,-0.002249968,0.016421478,0.0005409631,-0.01850078,-0.011417374,-0.022383815,0.040959753,-0.00070301717,0.0075907065,0.06904286,-0.0025912994,-0.0049915784,-0.026104013,0.0057055554,0.025778338,0.046345897,-0.027657228,-0.0228598,-0.00070184283,0.010045786,0.001968135,-0.017573863,-0.017072827,0.011818203,0.020417247,0.019377595,0.013740932,0.032266766,-6.125957e-05,-0.005386145,-0.0063944813,0.023711562,-0.069143064,0.0054706945,-0.011442426,0.0477488,-0.025427613,0.00954475,0.012601074,-0.00954475,0.009519697,-0.0148056345,0.01917718,-0.003170623,0.026204221,-0.011780626,0.041285425,-0.027907746,0.0443668,-0.005145021,0.021456897,-0.0037671698,-0.020342091,0.0077973837,-0.010910074,0.0021842069,0.021269009,-0.029110232,0.03449638,0.0031189537,-0.041260373,-0.02203309,0.0085050985,-0.0641327,-0.01466785,0.012156404,0.007628284,0.04053387,-0.00077582407,-0.025001733,-0.026630102,0.03314358,0.012976851,-0.00829842,-0.0047911634,0.015720027,-0.0017191822,0.039657056,0.009475857,-0.0027447417,-0.009939316,-0.027456813,-0.0041773934,-0.005677372,0.027657228,0.02436291,-0.0067577325,0.010064575,0.009350598,-0.023523673,0.021870252,-0.0382291,-0.004421649,0.019891158,-0.010315093,-0.037427444,0.0067827846,0.011254537,-0.033093475,-0.024838895,0.018400574,0.0422875,-0.03371977,0.016095804,0.01337768,-0.008204476,-0.03331894,-0.0031032963,-0.0029889971,-0.03261749,-0.01718556,-0.002099657,0.006125174,0.03304337,-0.016333796,0.010690871,0.023323258,0.024250178,0.03494731,-0.05842088,-0.022972533,-0.016809782,-0.018738773,0.015419405,0.019214759,0.06017451,0.027181242,0.026930723,-0.017598914,-0.06343125,0.009200287,-0.0013363588,0.011893359,0.018876558,-0.044441957,-0.0157075,-0.030913966,0.025126992,-0.0017724173,-0.0021873384,0.023498623,-0.03194109,-0.0018694933,0.01758639,0.0024503828,0.050679862,0.016847359,0.028534042,-0.03128974,-0.023223052,-0.019816002,0.0033788662,0.011348481,-0.019477801,-0.025628028,-0.006557318,0.042638224,-0.050153777,-0.07285074,-0.0027087298,0.039531797,0.0016377638,-0.03437112,0.011730522,0.017223136,-0.03998273,-0.011010282,0.055314455,0.014555116,-0.054813415,-0.039356433,-0.026529893,-0.01629622,-0.0038705086,-0.003140874,0.027657228,0.011567685,0.003482205,-0.030763654,-0.04451711,-0.009469594,0.0013919426,0.009601116,0.01337768,-0.031189535,-0.034972362,0.035824124,-0.02544014,0.029260544,-0.009463331,-0.022772118,0.0040333457,-0.00014287375,0.028358677,0.0055270614,-0.012594811,-0.011185645,-0.049176753,0.004694088,-0.0017457998,0.00897482,0.00719614,-0.02004147,-0.019703269,0.007171088,0.0024816976,0.057118185,0.021795098,-0.018726246,0.0031393082,0.010290042,-0.019891158,0.029135285,0.0054425113,0.0072650323,-0.0111981705,0.008837035,-0.023673985,0.010390249,0.007885065,0.009300494,-0.0013942913,0.018062374,0.028559092,-0.0131021105,-0.0016800388,0.03356946,-1.0195657e-05,0.00018123437,-0.030362826,0.020980913,-0.013327576,0.003410181,0.022772118,0.007528077,-0.00876188,-0.011542633,0.006068807,-0.032166556,0.0072525064,0.011505055,-0.02660505,0.018488254,-0.018150056,-0.04544403,0.029636322,-0.0055928226,0.013553043,0.020379668,-0.035698865,0.011943462,-0.0422875,0.022972533,-0.033744823,0.014818161,0.00011273326,-0.06513477,0.021507,0.022596756,0.011843256,0.0100520495,0.009488382,0.016884938,0.04804942,0.009325546,-0.041310478,0.0122691365,-0.04261317,-0.012876644,0.022884851,0.034270912,-0.05130616,0.00227502,-0.050554603,-0.012851592,0.0037201976,-0.044166386,-0.002321992,0.019715795,0.05170699,0.01500605,0.014016503,0.004872582,0.047097452,-0.048074473,0.014241968,-0.016759679,-0.0034665477,-0.0012940839,0.025978753,-0.019302439,-0.026379583,0.0015516481,-0.009889212,-0.023160422,-0.0038016161,-0.024312807,0.0056397947,0.042412758,-0.024738688,-0.025189621,-0.010665819,0.035648763,-0.004528119,0.009131394,0.0037609069,0.029010026,0.012788963,0.00035111714,-0.044166386,-0.015907915,-0.002707164,-0.029561166,-0.013039481,0.03574897,0.018813929,-0.01617096,0.015532138,-0.0063193254,0.03301832,0.0019195969,0.023774192,0.009338072,0.049051493,-0.028534042,-0.038930554,0.0029529852,-0.002808937,-0.040558923,0.043189365,0.0045343824,-0.017072827,0.016183486,0.05336041,0.014818161,-0.048675716,0.038179,-0.043590195,-0.02000389,0.0293357,-0.03782827,0.02114375,-0.008542676,-0.007509288,0.016859885,-0.008198213,0.008016587,0.014304598,-0.007609495,-0.0334442,2.121088e-05,0.013966398,-0.025164569,0.00015716112,-0.0071084583,-0.016684523,0.029435907,-0.008849561,-0.020880705,-0.0020902625,-0.026429687,0.023147896,-0.014479961,-0.006050018,0.016734626,0.024375437,-0.014542591,-0.004669036,-0.000914392,0.0025255382,0.014692902,0.06318073,0.009644956,-0.016158434,0.019477801,-0.0066387365,0.045920014,-0.0131021105,-0.032266766,-0.0019336885,0.0038767715,-0.011736785,-0.04121027,0.0008517624,-0.019001817,-0.027131138,0.030763654,-0.02470111,-0.031865936,0.01037146,-0.015143835,-0.037352286,0.017661544,-0.008887139,0.012695018,-0.037853323,0.023022637,-0.0059404164,-0.040634077,-0.025615502,0.035523504,0.011335956,-0.022571703,0.0089810835,-0.025878547,-0.0006638736,0.025640555,-0.029936943,0.030563239,0.055164143,-0.0069769365,0.0041178954,0.034847103,-0.01276391,-0.013239895,0.008692987,0.014580169,0.010271253,-0.00491016,0.058220465,-0.02878456,-0.026304428,0.027331553,0.010690871,0.04819973,0.010653293,-0.0010560914,-0.017987218,0.020868178,0.036475472,-0.0025521559,0.010120941,-0.004897634,-0.021982986,0.0011977908,0.007014514,0.025678132,0.020417247,-0.018726246,0.022246031,0.020091573,-0.016346322,0.004850662,0.017173033,0.0020135413,-0.0019102024,0.018926661,0.02101849,0.036525577,0.03469679,-0.019127076,-0.034045447,0.011862044,0.016872412,-8.210348e-05,-0.02715619,-0.04642105,0.0477488,-0.030062202,0.022772118,0.008511362,0.008968557,0.011498793,-0.039807368,-0.017436078,0.0034508903,-0.011749311,0.013527991,-0.013765984,-0.019076973,-0.0019759636,0.022847274,0.024012184,0.032191608,-0.062278863,-0.018676143,-0.02880961,-0.029410856,0.0010474799,-0.013415258,-0.013289999,0.021744993,-0.008523887,0.021469424,-0.0068140994,-0.0023783587,0.021807622,0.015306672,0.03985747,0.012206507,0.021206379,-0.020304512,0.008536413,0.023699036,0.011329693,0.039882522,0.00903745,0.014354702,0.008398628,-0.01026499,0.001275295,-0.014717953,0.043314625,-0.0029889971,0.0055990852,-0.013277473,-0.012588548,0.031590365,0.026429687,0.016897462,0.02491405,-0.0025709446,0.021657312,-0.010853708,-0.02783259,-0.01801227,-0.0023000718,0.01663442,-0.026078962,0.029035078,0.007164825,-0.0005773665,-0.006663788,0.006707629,-0.01248834,0.009889212,0.02169489,0.022747068,-0.02936075,0.017536284,0.006995725,0.011730522,-0.010296305,0.006250433,0.02838373,-0.048926234,-0.025903597,0.0069268327,0.0091376575,0.028483937,-0.0018898479,0.0010419998,-0.043740503,0.0037014086,-0.027531968,0.010139731,0.006864203,-0.0007597752,0.011411111,0.03151521,-0.014191865,0.004167999,-0.010070838,-0.04123532,-0.0031674914,0.008223265,0.013152214,0.015469508,-0.047022294,-0.007953958,0.022271082,-0.008367313,-0.009801531,-0.03439617,0.014580169,0.034746896,0.011542633,0.030212514,-0.008799457,-0.0018240868,0.014617746,-0.019014344,-0.006203461,-0.0005581862,0.0010623544,-0.005414328,0.025828443,0.02497668,0.06212855,0.020216832,-0.0069017806,-0.0286593,0.0023157292,0.0104466155,0.0072587696,0.0036356477,0.029285597,0.038554776,-0.008467521,-0.0052953316,0.015870338,0.027281448,-0.019678216,-0.019740846,-0.020141676,-0.017448604,-0.014342176,1.4495325e-06,0.02647979,0.011567685,0.019314965,-0.020091573,0.010822393,-0.04053387,-0.005047945,-0.0052922005,0.056466836,-0.014743005,-0.019527907,0.023172949,0.021231432,-0.017849432,0.051506575,0.011141804,0.0064508477,-0.00785375,-0.0477488,0.00079109,0.01669705,-0.00083845365,0.020793024,-0.010903811,0.03043798,0.027356604,-0.003369472,-0.034872156,-0.023122845,-0.012538444,-0.01902687,-0.026279375,0.009219076,0.009231602,0.0049352115,-0.014642798,0.017498707,0.042813588,-0.022045616,-0.0042149713,-0.023172949,0.033118527,0.025277302,0.019866105,7.6916964e-05,0.0019039395,-0.0024159364,-0.027231345,-0.009726375,-0.0071460363,-0.002256231,-0.029811684,-0.018726246,0.02074292,-0.025828443,-0.008674198,-0.012049933,-0.0079101175,-0.018463204,0.0011758705,-0.019127076,0.005336041,-0.019565484,0.009031187,0.003976979,0.045243617,7.642767e-05,0.013916295,-0.013678302,0.031790778,0.0043778084,0.015369302,-0.02294748,-0.050128724,-0.034346066,-0.00675147,0.001154733,-0.022083193,0.014843212,0.0104466155,0.01828784,0.0069456217,0.027206294,0.01957801,-0.02451322,0.047949214,0.00023740529,-0.010866234,-0.011899622,0.004199314,0.021644786,-0.013214843,0.0016158434,0.003369472,0.021557104,0.0054111965,-0.023511147,0.0238744,-0.014267021,-0.0014639667,0.035448346,0.025239725,-0.013465362,0.006347509,-0.03246718,-0.011191907,0.012538444,-0.020266935,0.005408065,0.023160422,-0.017974691,0.009369386,-0.0014295204,0.010227412,-0.035698865,0.0057995,0.04602022,0.009864161,-0.0035417033,-0.008179424,0.0031142563,0.0059560738,0.0131396875,-0.011918411,-0.0025051837,0.00499471,-0.017035248,-0.03875519,0.020079046,-0.025277302,-0.009594853,0.004415386,-0.019490328,0.012325503,-0.0022170874,-0.029661374,0.01809995,-0.016872412,0.0043652826,0.03928128,0.037227027,-0.0064633735,-0.017072827,0.02850899,-0.005846472,-0.03464669,0.0235362,0.00615962,-0.005680504,0.020492401,0.01764902,0.011548896,-0.0027259528,-0.01377851,-0.000748815,-0.024763739,-0.0154820345,-0.01132343,0.006457111,-0.012118826,-0.0002141149,0.032667592,-0.013014428,-0.0075844433,0.009400701,-0.028859714,-0.011235748,0.004108501,0.018738773,-0.017962167,-0.045945067,-0.0056304,0.022346238,-0.010465404,-0.0013551477,0.0091752345,0.0013042612,0.032266766,0.03574897,0.013302525,0.0016690786,-0.002761965,0.017699122,-0.043014,-0.043840714,-0.005902839,-0.040458716,0.0108036045,0.0073840288,-0.015882865,0.010239938,-0.020780498,0.0018522701,0.03657568,0.008624095,-0.004853793,-0.041986875,-0.017799329,-0.012156404,-0.020329565,-0.022471497,-0.01115433,0.0044435696,0.018738773,0.0075155506,-0.017711649,0.011004019,0.0108411815,-0.012726333,0.0025458927,-0.024074813,0.013202317,-0.0017379711,0.016008124,0.027206294,0.007177351,0.012507129,0.024964154,-0.0062974053,-0.04777385,0.021168802,0.0088996645,0.0070771435,0.012682492,-0.001449875,-0.004158605,-0.00448741,-0.013352629,-0.0047254027,0.0035291773,0.024162496,-0.034446273,0.0027275186,0.028458886,0.028433833,0.022534126,0.02559045,-0.014692902,0.003194109,-0.000100696634,-0.0072337175,0.023573777,-0.007866276,-0.0010185137,-0.025089413,0.019753372,0.0055270614,0.0041648676,-0.036650836,0.013515465,0.011160593,0.014367227,0.00635064,0.06102627,0.0018115608,-0.0293357,-0.02055503,0.0011516016,0.022546653,0.019603062,-0.01724819,-0.004139816,0.0049258173,-0.0007844356,-0.024625955,-0.0006396047,-0.041160166,-0.0015986203,-0.023824295,-0.0133401025,-0.0055959537,-0.00054996606,-0.042062033,-0.012569759,-0.050780073,0.037728064,0.036826197,-0.04176141,0.00228598,0.006826625,0.010941389,-0.034746896,0.0014694467,0.049452323,0.02389945,0.016496634,0.019690743,-0.0021685495,-0.03301832,-0.018212685,0.0068328883,0.0006987114,-0.0028590409,0.0007699525,-0.029511062,0.02546519,-0.008567728,-0.016408952,-0.007734754,0.020755446,0.011530108,0.011436163,-0.018513307,0.021431845,0.014918368,0.014755531,-0.015269094,0.030513136,0.024275228,-0.010440352,0.01617096,0.0069205696,0.051556677,0.025239725,-0.017836908,0.05486352,0.0096512195,-0.018513307,0.0031596627,0.0016095805,0.012613599,-0.015632346,-0.017411025,0.017824382,0.011730522,-0.0150436275,-0.0046032746,-0.029135285,-0.0006717023,0.018488254,0.011004019,-0.0029796027,0.042462863,-0.00914392,-0.019490328,-0.016684523,0.00088620867,-0.039406538,0.022759592,0.0055270614,0.018325418,-0.0024128049,-0.008999872,-0.009538487,-0.03316863,-0.0072650323,0.012951799,0.008335998,-0.017097877,-0.010133468,-0.011035333,-0.019878631,0.011567685,0.031415,0.00096762716,0.033544406,-0.018275315,-0.0056523206,0.024413014,-0.0148056345,0.0030751128,0.02040472,-0.016797256,-0.026855567,0.016897462,-0.012770173,0.046922088,0.0024268965,-0.06423291,0.0061878036,-0.0014749268,-0.015131309,0.005367356,0.032943163,-0.013390206,0.015456983,-0.005298463,-0.027632175,0.00041766107,0.007308873,0.0058026314,-0.01820016,-0.016897462,-0.01945275,0.007227455,0.027181242,-0.013966398,-0.034195755,0.042137187,-0.019690743,0.01617096,-0.0013277472,0.025277302,0.007014514,-0.017097877,-0.01460522,0.000685794]	2025-06-22 10:36:59.578249-04	0
ads	5babb65f-dac7-4d80-97d9-4bba295bc55b	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	307e1eac-5b7e-4fc3-b223-79f49b32ad6f	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	3a030305-7f88-41c6-9892-e87204ad1448	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	000d2b04-8e9a-4db4-bd75-3c07f032da3d	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	4e2286f1-9be1-4f3a-89bf-e551fa28d1b4	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	16ae66a3-2c01-4aaf-a057-2b550ce77b66	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	67e793f5-c51f-4f70-934a-068ae4abd748	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	59d35128-30a1-47fb-ad2c-5760d48e9950	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	7a7f63c8-27a7-4462-99f6-8a5c88d704d1	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	61d7d76b-7c60-4ccf-bae7-9279adbf8bf6	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	bdfc0914-702d-4fea-bdcc-c1a139ba8adb	[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]	2025-07-19 08:31:36.301413-04	0
ads	c1d78b05-e8fa-4bba-8cae-11a140df064a	[0.030047497,-0.023547323,-0.06383829,0.026177743,0.010559621,-0.05761633,0.025697187,0.048283394,0.0035377892,0.009320289,0.031312123,0.0051976102,-0.04178322,-0.056554046,0.011583968,0.032349117,-0.08467931,-0.06282659,0.008024048,-0.010957979,-0.03652238,0.043199603,0.007043963,0.03743291,0.04651292,-0.0036927059,-0.049269803,-0.027467662,0.028454069,-0.007688922,0.024192283,-0.04438835,0.027012397,-0.03581419,0.011394274,0.009598507,-0.0067025144,-0.009649091,0.02220682,0.00041851195,0.005128056,0.030730395,0.03887458,0.07704098,0.024103759,-0.0016898556,-0.015694,0.03078098,-0.0027173636,0.0028043066,-0.016136618,-0.008839731,-0.015175504,0.00088207616,-0.029212845,-0.0034302962,0.0058741844,0.009611152,-0.03057864,-0.0069680857,0.05255783,-0.0017515061,0.034777198,-0.008662684,0.009238088,-0.0253178,-0.0391528,0.028782872,-0.06550759,-0.016086034,0.0034271346,0.028125267,-0.026658302,-0.009503659,0.035763603,0.0055422205,-0.0117294,0.0016882748,0.013303858,-0.054530643,-0.049092755,-0.0009279188,-0.0046822755,0.021827433,-0.035004828,-0.016895395,-0.019626984,-0.04967448,-0.06495116,0.0015641834,-0.040923275,0.022624146,0.016073387,0.012564053,-0.00570346,0.046968184,-0.00956689,0.037812296,0.02875758,0.058982126,0.0014875155,0.001488306,-0.044363055,-0.009294996,0.025469555,-0.010407866,0.011217226,-0.022636794,-0.0017341175,0.0017167289,-0.11401862,-0.010970625,-0.027720587,0.043730743,-0.012892855,-0.05174847,0.025848942,-0.0459059,0.021587154,-0.0115966145,-0.06146079,0.006746776,-0.0061618867,0.018653223,-0.016794223,-0.048435148,-0.03007279,-0.011976002,-0.022181528,-0.03196973,0.005624421,0.02572248,0.04127737,-0.025469555,-0.023901418,-0.029718695,-0.040316254,-0.019993726,-0.010660792,0.027214738,0.02794822,-0.03895046,0.044540104,0.012608315,-0.02068927,0.011621906,0.0026240975,0.005611775,-0.024862533,0.034549564,-0.0408474,-0.021308936,-0.04137854,-0.027391784,0.04309843,0.0048340303,0.054631814,0.034271345,-0.03252616,-0.033740204,-0.016225142,-0.0136832455,-0.0134556135,0.007821708,-0.019184366,0.062168982,-0.013480905,0.009731292,-0.049775653,0.031135075,-0.017666815,-0.006263057,-0.02885875,0.008409758,0.017540352,-0.020398406,0.0340943,-0.011938063,0.0010117003,-0.05458123,-0.009200149,-0.022839133,-0.017527707,-0.024508439,-0.048460443,0.013354443,0.029035797,-0.02321852,-0.024748718,-0.041530296,-0.021776848,0.01704715,-0.010692407,0.022396514,0.035485387,-0.0025071197,0.04461598,0.0030271967,0.05488474,-0.0076762754,0.03401842,-0.00045210356,-0.012089818,0.032450285,0.00988937,-0.014935225,-0.037078813,0.045830023,-0.032829672,0.0020787278,0.046993475,-0.0059058,-0.009294996,-0.009592183,0.01745183,0.0026114513,-0.034271345,0.005728753,0.025950111,0.059538558,-0.084780484,0.025848942,0.01704715,0.043427233,-0.0012164115,-0.007448643,0.0077837687,-0.001889034,0.021195121,-0.041327957,-0.014935225,0.027240029,-0.03723057,0.0019743962,0.07597869,0.020777794,0.0100095095,-0.017477121,0.022763256,0.021764202,-0.0045811054,-0.055289418,0.0013950398,-0.004400896,0.00723998,-0.011925417,-0.012722131,-0.0015839433,-0.00052205316,0.019829325,0.046184115,0.05963973,0.014492606,0.011293104,0.074663475,-0.029314015,-0.026329499,0.03675001,0.0059342543,0.000618876,-0.005045855,-0.03821698,-0.02784705,-0.019197013,0.011590291,0.05012975,0.0053177495,0.03169151,0.0034935274,0.0012338001,0.031438585,-0.008681653,0.009547921,0.01539049,0.019019965,-0.049522728,-0.016351605,0.006297834,-0.004827707,0.025090165,-0.0017578292,0.0002756488,0.004720214,-0.006348419,0.0029576425,0.015643416,0.09135653,0.05630112,-0.02885875,-0.027062982,0.0142270345,-0.0234588,0.04097386,-0.03057864,-0.0012764812,0.0010780931,0.005169156,0.034347225,0.016465422,0.015200797,0.051622007,-0.05116674,0.040290963,-0.0018131565,-0.011716753,0.07678805,-0.028024098,-0.023838187,-0.028049389,0.03429664,-0.015200797,0.0024565347,0.054227132,-0.036775306,-0.02956694,-0.026455961,-0.035890065,-0.0597409,-0.048915707,-0.05731282,-0.003294349,-0.05488474,0.00453052,0.0207525,0.030098082,-0.0085362205,0.032273237,-0.021068659,0.010034801,-0.04198556,0.0158584,-0.022636794,-0.037331738,-0.050888523,0.01599751,-0.026860641,0.0344231,-0.035965946,-0.02477401,-0.025368383,0.015162857,-0.08442639,-0.018678516,0.021915957,0.057565745,0.0026493901,0.021878017,-0.024053173,0.0072652726,0.049193926,-0.029288722,-0.010837839,0.015276674,-0.012387005,0.0049130693,0.041707344,0.014062634,-0.03558656,-0.028302314,-0.023559969,-0.05700931,0.034701318,0.07026258,0.0027189443,0.027164152,0.04390779,-0.053721283,-0.0033702264,0.014669654,-0.00469176,0.020841025,0.026203036,0.048688076,-0.0053778193,-0.037179984,-0.045577098,0.049421556,0.04562768,0.041555587,-0.0007730022,0.03884929,-0.008770176,-0.006689868,-0.017578293,0.023509385,0.01498581,-0.016465422,-0.014631715,-0.038115807,0.033689618,0.054834154,-0.034347225,-0.037483495,-0.0013673761,-0.009174856,0.06662046,0.03067981,0.018956734,-0.0053588497,0.017666815,0.014492606,-0.019159073,0.005731914,0.015011103,-0.005327234,-0.038469903,0.013784416,0.011659846,-0.00020728,0.0030793627,0.04785342,-0.056351703,0.025507493,-0.037685834,0.025848942,-0.016617177,-0.005067986,0.023800248,0.008011402,-0.002772691,0.0026525515,-0.008510929,-0.009908339,-0.0030493278,-0.007739507,0.03247558,0.0013136296,0.0014448344,0.0012100884,-0.041606173,-0.005371496,0.0014511575,0.011950709,-0.023989942,-0.014669654,0.027417077,-0.06156196,0.014517899,0.0411762,0.0052734874,-0.01795768,0.017236844,0.020044312,-0.029769279,-0.015883693,-0.03540951,-0.03379079,0.013809709,-0.045855314,-0.041934974,-0.01377177,-0.025924819,-0.02946577,0.030932736,-0.05903271,0.021814786,0.020701917,0.028454069,-0.0155422455,0.03429664,-0.01049639,-0.014606423,-0.011236196,-0.005807792,0.009946278,-0.044540104,-0.010957979,0.02865641,0.00034105364,0.0011642457,-0.01626308,-0.0123680355,0.025469555,0.06925088,-0.030300424,-0.019285535,0.029895743,-0.0071071945,-0.0054378887,-0.03320906,-0.026810057,0.0015981703,-0.044489518,0.0205881,-0.03692706,0.025671894,-0.014290266,-0.018779686,-0.06874503,-0.016389543,0.0089219315,-0.017401244,0.028403485,-0.013835001,0.009845108,-0.024103759,-0.02744237,0.018172666,0.000792762,0.031742096,0.014631715,-0.032602042,-0.011116057,0.0361177,0.029035797,0.013531491,0.030022206,0.0051343786,-0.023534678,0.033917252,0.011938063,-0.025874235,0.0015230831,0.058071595,-0.011135026,-0.041732635,-0.0024217574,0.09287408,-0.008744884,-0.044059545,0.0009674384,-0.004805576,-0.01951317,-0.029693402,-0.013430321,-0.015479014,-0.007638337,-0.023205874,-0.06282659,0.0077774455,-0.012469206,-0.0050142393,-0.0067847148,0.010369928,-0.04330077,-0.019019965,0.008359173,-0.008397112,-0.04572885,0.0004896471,0.023952004,0.011944386,0.043022554,-0.00596587,-0.00825168,0.003727483,-0.008283296,-0.034170177,-0.017742693,0.0030461662,0.035991237,-0.021663032,0.04097386,-0.002453373,0.008529898,-0.0035377892,0.012228927,-0.004220687,0.030401593,0.015479014,0.016048096,-0.023231167,-0.017730046,-0.012190988,0.00928235,0.042946674,-0.00021063915,-0.030351007,0.0023885611,0.014340851,-0.015959572,0.013278566,0.0021261512,-0.023989942,0.040796813,0.0059627085,0.05437889,-0.009326612,0.010724023,0.008270649,-0.040113915,-0.023041474,-0.016971271,0.009117949,-0.008669007,0.024230221,-0.014555837,-0.0065254667,0.026759472,0.008890316,0.013898232,-0.01041419,-0.018653223,-0.016983919,0.005169156,0.0061840178,-0.01785651,0.03692706,0.03490366,-0.034549564,0.0002657689,0.00019374455,-0.048612196,-0.004625367,-0.0077205375,-0.01140692,-0.015529599,-0.019197013,0.0061587254,-0.032273237,0.0046000746,-0.019095842,-0.021915957,-0.0030856857,-0.003771745,-0.015036395,0.01984197,0.014606423,0.030502763,0.0073158573,-0.0030509087,-0.010711377,0.013822354,-0.008441374,0.013000349,0.031843264,-0.023496738,-0.040215086,-0.008043017,0.019361414,0.025355738,0.04479303,0.026025988,0.0016044934,-0.017173612,-0.042213194,0.005886831,0.012102464,0.00323586,-0.04340194,-0.01508698,-0.017603584,-0.043680158,0.009364551,-0.00754349,0.001998108,0.016971271,0.0067214835,-0.004951008,0.030907443,0.028884042,-0.019019965,0.04603236,0.0035883742,0.024963703,0.034751903,-0.014315559,-0.0059563853,-0.0012132499,-0.013405029,-0.024015235,0.007195718,-0.055137664,0.012361713,0.0063579036,0.0023616878,-0.004641175,0.028605824,-0.054631814,-0.019816678,0.005529574,0.020411052,0.036497086,-0.011337366,0.019361414,-0.0007141181,0.03449898,-0.046361163,0.04198556,0.0062156334,0.031843264,0.0015207119,-0.026329499,-0.03533363,-0.0027458176,0.0034302962,-0.027138859,0.025305152,0.012601991,-0.05852686,-0.022320637,0.012387005,0.0033702264,-0.03252616,0.0020771471,-0.033360817,0.032652624,0.009130595,0.015681354,-0.08973781,-0.006689868,0.037205275,-0.02457167,-0.06333244,-0.039734527,-0.03300672,-0.012601991,-0.035788897,-0.00050308375,0.016250435,-0.006231441,-0.03078098,-0.011773662,-0.0064464277,-0.0012369617,-0.039608065,0.007410704,0.009857754,0.022864426,-0.02173891,-0.053013094,0.0030192928,-0.024647547,-0.0009927308,-0.022687377,-0.005735076,-0.019905202,-0.026885934,-0.0033101568,-0.01714832,-0.02663301,-0.01326592,-0.014707592,-0.011906448,0.0077774455,-0.0030572317,-0.011299428,-0.044970077,0.0039393078,-0.03824227,0.0017783793,0.053721283,-0.012159373,0.03298143,0.03793876,-0.017262135,0.052911922,0.020904256,0.028909335,-0.00459059,-0.014846701,0.009212796,-0.014796116,0.01286124,-0.021030718,-0.023901418,0.009092656,0.0062567336,-0.008687976,0.028277023,-0.004685437,0.026582424,-2.3575876e-05,0.030553348,0.001933296,0.01142589,-0.01437879,-0.014859348,0.004170102,0.025203982,0.009977894,-0.020878963,-0.026885934,0.011564999,-0.03925397,-0.013000349,0.0009097398,0.0069997013,0.010464774,-0.015162857,0.023092058,-0.0008678491,0.008959871,0.011805277,-0.007922878,-0.0053778193,0.0033891958,-0.011672492,-0.011362659,-0.021726264,0.003749614,-0.025128106,0.01987991,0.013544138,0.009111625,0.0071135173,0.016149266,-0.031261537,0.021675678,0.01589634,0.01447996,0.008744884,-0.009661738,-0.004815061,-0.01666776,-0.013164749,-0.04077152,0.016440129,-0.033563156,0.009560567,-0.028378192,-0.027062982,0.014024694,0.02815056,0.0009927308,-0.0020755662,0.0026446476,-0.032753795,0.0046949214,-0.0015286158,0.01903261,-0.00734115,0.016427483,0.0061776945,0.005124894,0.0036357979,0.0024596963,0.022864426,-0.0024217574,-0.0083781425,0.020461638,0.019121135,0.021915957,0.020980135,0.0058583766,0.07501757,-0.05093911,0.026253622,-0.0017214712,0.021182474,-0.01623779,-0.056655213,-0.004407219,-0.0026667786,0.013278566,0.006930147,0.026076574,0.009434105,-0.016440129,-0.018248543,-0.058172766,-0.028378192,-0.019664925,-0.012842271,-0.0013997821,0.014442021,0.034043714,-0.01812208,-0.023003535,0.033234354,-0.026759472,0.019829325,0.023737017,-0.0053746575,0.007884939,-0.018615285,-0.0038412993,0.0038634303,0.030629225,0.044970077,-0.0069617624,-0.0010741411,-0.04259258,0.009699676,0.019905202,0.006595021,-0.0028201144,0.0054789893,-0.007859646,-0.024381977,0.020019019,0.015820462,0.029921034,-0.03252616,0.023294399,0.017401244,-0.0027521409,0.033436693,-0.012045556,-0.020575454,-0.017338013,-0.010749315,0.0124818515,0.0117104305,-0.009149564,0.004944685,-0.022181528,0.033664327,-0.013076226,-0.006955439,0.010382574,0.0024438885,0.010388897,0.017692108,-0.021435399,0.009870401,0.013923525,-0.010420512,-0.0024233384,0.004331342,0.028125267,-0.021625092,-0.0004058657,-0.016326312,-0.0061776945,0.0027173636,-0.0039045308,0.022105651,-0.014846701,-0.021814786,-0.0011942806,-0.02392671,-0.019411998,-0.0022826488,0.051900223,-0.003193179,0.006354742,-0.021688323,0.03540951,0.04441364,-0.03202031,0.035864774,-0.00764466,-0.019563753,0.011893801,-0.031210953,0.00016746405,-0.0044704503,0.00794817,-0.030907443,-0.027088275,0.0053999503,-0.04934568,-0.04231436,0.03755937,-0.026582424,0.02180214,-0.00764466,0.0185647,-0.0005943739,-0.0034208114,-0.0002487755,0.016301021,0.011381628,0.023952004,-0.02048693,0.0028058875,0.010603883,0.005191287,0.04188439,0.037964053,-0.028706994,-0.01846353,-0.027897634,0.0077015683,0.039102215,-0.0158584,-0.006847946,0.041226786,0.0014369305,-0.013822354,0.0090357475,-0.019664925,-0.01528932,-0.0050553395,0.021245705,0.007865969,-0.015567537,0.04327548,-0.022649439,0.013645307,0.028782872,0.0459059,-0.010464774,-0.01397411,0.020638686,-0.0076573063,0.015314613,-0.001512808,0.010015832,-0.041555587,0.033032015,-0.013329151,0.0068036844,0.024483146,0.01294344,0.016958626,0.031109782,-0.018842917,0.026708886,-0.019348767,0.007252626,0.020360468,-0.010388897,0.0012061364,-0.0044419966,0.048460443,0.0037211599,-0.01826119,0.010717699,0.008909285,-0.016427483,0.048460443,0.012197311,0.025039582,-0.018033557,-0.044034254,-0.02815056,-0.030654518,-0.021308936,-0.0068036844,-0.008024048,-0.014138511,-0.0058552152,0.0032263754,0.0106671145,-0.012671546,0.0010338312,-0.032273237,0.03632004,0.0064337812,0.016857456,-0.04572885,-0.029718695,-0.0031315284,0.014745532,-0.001947523,-0.0459059,-0.017603584,0.0064242966,-0.02433139,-0.010850485,0.008156833,-0.015479014,-0.009611152,0.013797062,-0.0013294374,0.006949116,0.052355487,-0.018855564,0.040493302,-0.0098514315,-0.011356335,-0.0060828477,-0.009876723,0.008156833,-0.030856857,-0.027391784,-0.034777198,-0.00999054,-0.026810057,-0.0021846402,0.035864774,-0.038292855,0.038292855,0.018893503,0.019310828,-1.8722383e-05,0.00012685773,-0.021068659,0.021460691,-0.021574508,0.017590938,0.017692108,0.006389519,-0.010363605,0.001773637,-0.022055065,0.00908001,-0.044970077,0.00035093352,-0.0003598254,-0.022535624,-0.007979786,0.0042396565,0.014454667,0.0016297859,-0.01619985,0.020170774,0.002562447,-0.0148846395,-0.042415533,0.008953547,-0.032045607,-0.012507144,0.010970625,0.013139457,0.00976923,0.035763603,0.0061776945,-0.016452776,0.032323822,0.005712945,0.0057161064,0.0027173636,0.008384466,0.016705701,-0.021726264,-0.013177396,-0.021081304,0.01927289,0.00061492407,0.025760418,0.013594722,0.023446154,0.018273836,-0.026759472,0.05116674,0.00988937,0.017034503,-0.013329151,-0.021043366,-0.00048055762,0.030401593,0.028277023,-0.00018287668,0.04137854,0.011621906,-0.024015235,0.048384566,0.012564053,-0.0012345904,-0.011375304,-0.013202689,0.022497684,-0.035864774,0.0002497635,-0.01836236,-0.029592233,0.0045178737,0.021991834,0.009718645,0.013708538,-0.026582424,0.01704715,-0.012475529,0.015731938,0.06692397,-0.015845755,0.037964053,-0.0113247195,0.016086034,0.027492955,-0.03533363,0.044438932,0.006247249,-0.002614613,-0.017590938,-0.017881801,0.0207525,0.000673413,-0.012051879,-0.004182748,-0.018071495,-0.032551456,0.0069680857,-0.014669654,0.010970625,-0.010863132,-0.010218172,-0.005731914,-0.0061776945,0.0012132499,0.0022684217,-0.011318397,0.012115111,-0.03723057,0.013379736,0.019740801,0.02916226,-0.014391436,0.008915609,0.011742046,-0.020714562,-0.037964053,0.0011255165,0.0088587,0.009933632,-0.008637391,-0.0060923323,0.034195468,0.033057306,0.013784416,-0.01589634,-0.025330445,-0.032956135,-0.025052227,-0.016857456,-0.021587154,0.015871048,-0.00244705,0.0155422455,0.028403485,0.030199252,-0.0059627085,0.0048972615,0.049573313,-0.01326592,0.021776848,-0.05984207,0.038697533,-0.043174308,0.0010812547,-0.02521663,-0.025760418,-0.023838187,0.008245357,0.04562768,0.004473612,0.028175851,-0.04803047,0.030705102,0.0088587,-0.011071795,-0.015124919,-0.012595668,-0.0018479337,-0.029794572,0.042946674,0.022156235,0.027265321,-0.031337414,0.019867264,-0.010932686,0.014707592,-0.027670002,-0.0072652726,-0.007556136,0.022965595,0.049725067,-0.014606423,-0.028201144,0.02281384,-0.009547921,-0.0049383617,-0.0065128203,0.045071248,0.0050648246,0.027417077,-0.025545431,0.015124919,-0.018311774,0.02784705,-0.016996564,0.015238735,-0.008890316,0.010534329,-0.0026683593,-0.015251381,-0.0040594474,0.0054125963,-0.0071704257,0.02558337,0.023193229,0.033386108,-0.009864078,-0.024887826,0.01765417,-0.034979537,0.025064874,-0.016819516,0.013860294,-0.0205881,0.03460015,-0.012241573,0.03300672,-0.014644361,-0.004928877,-0.003765422,-0.0020075927,-0.022990888,-0.0005489264,0.0077142143,-0.004742345,-0.008435051,0.037660543,0.015074334,-0.024685485,-0.006133433,0.010218172,-0.018716455,0.019323476,-0.005327234,-0.015099626,0.01437879,-0.049522728,8.6202e-05,-0.012924471,0.0061808564,-0.0117294,-0.0044356734,-4.3841992e-05,0.027391784,-0.005289295,-0.01326592,-0.0063452576,0.021675678,-0.039304554,-0.036497086,-0.03252616,-0.019639632,0.009611152,-0.028099975,-0.016832164,0.0075245206,0.033740204,-0.0051944484,0.012001295,0.012722131,-0.029693402,0.025444262,0.013847647,-0.028403485,0.0110528255,0.01724949,-0.05711048,-0.012241573,-0.00926338,-0.011419566,0.01714832,-0.00956689,0.030730395,-0.007429674,-0.025975404,-0.013657954,-0.018741747,0.011236196,0.025052227,0.0039203386,-0.032551456,0.02433139,-0.002976612,0.016389543,-0.015061688,-0.023850834,-0.030755688,0.01599751,-0.026582424,0.022573562,-2.1044156e-05,0.03563714,0.003265895,0.021384815,0.0013484068,0.0038571071,0.033563156,0.007796415,0.00632945,-0.006149241,0.0049921083,-0.0056149364,0.015137565,-0.014391436,0.01110341,0.023155289,0.029086383,-0.0023774956,0.0063168034,-0.038596366,0.017477121,-0.046310578,-0.031817973,-0.017590938,0.009939955,0.0041953945,0.02034782,-0.0050363704,-0.008302265,0.019766094,0.029794572,-0.012614638,0.0361177,-0.024660194,-0.031539757,-0.019386707,0.0041795867,0.01910849,-0.016705701,-0.014871994,-0.005090117,0.008099925,-0.020044312,0.025166044,0.03189385,0.02281384,-0.010768285,-0.0035567586,-0.01241862,0.031919144,-0.001955427,0.027973512,-0.05015504,-0.016516007,-0.005820438,-0.021878017,-0.014998456,0.00087259145,-0.023989942,-0.023408215,-0.0046443366,-0.017224196,-0.019095842,-0.0062219566,-0.005915285,0.013430321,-0.015074334,-0.00036713653,0.029642817,-0.0018463529,0.0071008713,0.0055200895,-0.008005078,0.024963703,0.009136918,0.004900423,-0.041859098,-0.025899526,-0.038318146,0.030401593,-0.0045178737,-0.024647547,-0.004704406,0.0011397436,-0.013645307,0.0018431915,0.039001044,-0.0273412,0.0033259646,0.016857456,-0.028302314,0.019399352,0.0046759523,0.003771745,-0.013493552,-0.024293453,-0.0607526,-0.0004718633,0.0031504978,0.0028264376,0.002888088,0.011185611,0.038823996,0.0058836695,0.037407618,0.011362659,0.012671546,0.009775554,0.005219741,-0.021764202,-0.00053707056,-0.0026762632,0.0014677558,0.008093602,-0.00028789986,0.004546328,-0.01508698,0.017881801,-0.028403485,0.01795768,0.034777198,0.009958925,-0.022181528,-0.017742693,0.023572616,-0.015757231,0.036067113,0.0344231,0.019386707,0.002533993,-0.010401543,-0.02008225,0.025823649,-0.05106557,0.018956734,-0.0009097398,0.002331653,-0.023205874,0.009617476,0.016794223,0.035257753,0.031059198,0.026885934,0.030755688,-0.00031220439,0.008232711,-0.0039361464,-0.009345581,-0.012494498,0.03824227,0.005264003,0.005270326,0.002526089,0.0074170274,0.033259645,-0.0146823,0.015314613,-0.013531491,-0.012519791,-0.010641822,0.026025988,0.020512223,0.0018479337,0.061814886,-0.011533383,0.019551108,-0.006196664,-0.0069617624,0.027189445,0.025153397,-0.01998108,-0.029212845,-0.04668997,-0.0045716204,-0.0567058,0.0496239,-0.005690814,-0.013607369,0.04201085,-0.021220412,0.011678815,0.031388,0.052507244,-0.0011041759,-0.01387294,-0.022383869,0.03310789]	2025-08-06 10:23:30.428393-04	0
ads	08faa528-8b4f-4c9e-9dd7-cd203ce61d69	[-0.014794771,-0.011702046,-0.012599565,-0.012725332,0.046808183,-0.068417236,-0.004264644,0.024878995,-0.028652005,-0.031007279,0.056389343,-0.027074201,-0.02292389,0.018476313,0.0395137,0.023849994,-0.030549943,-0.020637218,0.013857235,0.0019779718,0.023506993,-0.047151186,0.0020279926,0.022054955,0.051815998,0.011993597,-0.038004495,0.05899615,-0.0029612407,0.07431685,-0.004164602,-0.015137771,-0.016223941,-0.0132627,0.057898548,-0.06786844,0.04342391,-8.5247775e-06,0.04509318,0.01049011,-0.036838293,-0.0053851134,-0.004559053,0.008192004,0.018727846,0.04280651,0.0263196,-0.047105454,0.0130226,0.009981325,-0.022500858,0.004730554,0.021849155,0.024810396,-0.023781393,-0.0033042417,-0.049209192,-0.00090537936,-0.0022480849,-0.0076089026,0.010415793,0.013445634,0.004356111,0.029863942,-0.026113799,-0.0154922055,-0.038804833,-0.052319065,0.025770798,-0.026845535,-0.020762986,0.019539615,0.04584778,-0.007494569,0.02332406,-0.0047048284,-0.0069857845,0.027966004,0.074545525,-0.01629254,-0.035054687,0.01210793,0.02540493,-0.0011912134,-0.05529174,-0.017653111,0.010873128,-0.010581576,-0.03148748,-0.03411715,-0.021094553,0.024101527,-0.02216929,0.006997218,0.014474637,-0.0072544683,0.022020655,0.03761576,-0.026365334,-0.013617135,-0.0016935668,0.0032756582,0.0049392125,0.007185868,0.08328061,0.04971226,0.03624376,-0.041640304,0.022889592,0.0055909143,-0.14140782,0.0026268149,-0.018110447,-0.03754716,-0.017698845,-0.02924654,0.024535995,-0.03253935,0.020625785,-0.027623003,0.014954838,0.020054117,-0.01043866,0.003155608,0.0019693966,-0.046259385,-0.0004984231,-0.057715613,0.006196882,-0.018487746,0.013388467,0.010804527,0.063706696,-0.011330462,0.009684058,-0.019196615,-0.032219216,-0.014680437,0.015286406,-0.024261594,-0.004784862,-0.0038902014,-0.035855025,-0.004987804,0.033111017,-0.033568352,0.007220168,-0.02387286,-0.028949274,0.0047162618,-0.014326002,0.009100956,-0.0035729257,0.046099316,0.031990547,0.017435877,0.0047734287,0.0019265215,0.020454286,-0.01179923,-0.043035176,-0.0061282823,0.0017678837,0.042966574,0.029818209,-0.037524294,0.020477151,0.005945348,-0.051678795,0.0061054155,0.0117763635,-0.012050764,0.019528182,-0.0031584664,0.0043761195,-0.022649491,0.009987042,0.007351652,-0.03853043,-0.009535424,-0.02020275,0.0064655663,-0.011753497,-0.049666524,-0.032470748,0.01832768,-0.00229096,-0.027005602,-0.035008956,-0.017150043,-0.057029612,-0.010032775,0.004902054,0.04866039,0.02087732,-0.008374938,-0.004278936,-0.017424444,-0.03491749,-0.043515377,-0.006402683,0.024924729,-0.014577537,-0.023175426,0.05584054,-0.029406607,0.012130797,-0.024170129,0.010993178,0.004759137,0.057990015,0.008763672,-0.0032470748,0.031075878,-0.010633027,-0.021357521,-0.012016464,-0.0040388354,0.009826975,0.025153397,0.016772741,0.021448987,-0.006202599,-0.0008846564,0.019185182,0.02192919,0.018156178,0.019333815,0.0267312,0.025816532,0.023289759,0.0037244176,0.013479934,-0.020762986,0.053965468,-0.0020865886,-0.013331301,-0.004441861,-0.004113152,-0.018510614,-0.019059414,0.008066237,-0.029681008,0.01193643,-0.0058481647,-0.0016907085,-0.0058538816,-0.049666524,0.0065113,0.008232021,0.033133883,0.055017337,0.08570448,-0.03189908,0.042829376,-0.028995007,0.012919699,-0.00062776305,0.012873966,-0.02931514,-0.025885131,0.021803422,-0.018156178,-0.021094553,0.008780822,0.04934639,-0.0010997466,0.033133883,0.011604862,-0.056663744,0.015823774,-0.0043446776,0.059773616,0.00924959,-0.014428903,-0.07728953,-0.044132777,0.019299515,-0.052227598,0.028949274,0.026845535,-0.021448987,0.0073402184,0.018190479,0.04216624,0.0148062045,-0.024970463,0.031807613,-0.01761881,-0.032219216,0.023289759,-0.00023795685,0.0003987385,-0.03434582,0.068417236,-0.018167613,0.061374288,0.020431418,-0.013708602,0.058676016,0.045984983,-0.066633634,-0.008855139,0.02009985,-0.02540493,0.053005066,-0.012908266,-0.006739967,0.025016196,-0.034322955,-0.015800906,-0.026342466,-0.03624376,-0.044247113,-0.046099316,-0.10811387,0.021266054,-0.032425016,0.008283471,-0.0152978385,0.022226457,-0.0059624985,0.032676548,0.015377873,0.006762834,0.039422233,0.01713861,0.026205266,0.054148402,-0.020008383,-0.03676969,0.009815541,-0.024627462,-0.020397117,-0.029703874,-0.057624146,-0.014097336,0.009604025,-0.024878995,-0.014863371,-0.0130226,0.026433934,-0.014874804,-0.013056899,0.05991082,0.039628033,-0.018933648,0.02401006,0.0073459353,-0.03217348,-0.059865084,-0.0121650975,-0.010232859,0.04495598,-0.029841075,-0.018304814,0.008323488,0.01200503,0.001267674,0.01860208,-0.027828803,-0.011496246,0.045207515,0.008609322,0.0049735126,0.047928654,-0.013377034,-0.051770262,-0.016978543,-0.033202484,0.029520942,-0.0017407294,-0.0051307213,0.00094539614,-0.043538243,-0.008580739,-0.034528755,0.005802431,0.052181866,0.030321276,0.014005869,0.00787187,0.03679256,0.009026639,0.040931437,0.02234079,-0.0130454665,-0.017458744,0.024558863,-0.00394451,0.0014270265,-0.038690496,-0.0027640152,0.020934487,0.047242653,-0.0015249246,0.0026425358,-0.01731011,0.011879263,0.033248216,0.0110389115,0.045070313,0.04774572,-0.0011819238,-0.010267159,-0.044292845,0.015034871,0.006225466,0.01812188,0.0050649797,0.020408552,-0.016201075,0.012896833,-0.012130797,-0.02826327,-0.046876784,-0.025907999,-0.03754716,-0.02485613,0.044567246,0.019493883,-0.024901863,-0.04893479,-0.011210412,-0.0408857,0.011136095,0.028217537,-0.01030146,0.018693548,-0.061099887,-0.028857807,-0.0076089026,0.019299515,-0.050215326,0.007980486,-0.024467396,0.022089256,-0.022809558,0.054422803,0.034871753,0.03274515,0.009764091,-0.018442012,-0.033568352,-0.014188803,-0.027943138,-0.061968822,-0.012302298,0.025885131,0.0062711993,0.0033614086,-0.06635924,0.016349709,-0.020820152,-0.021597622,0.004170319,0.032310683,-0.041846104,0.035855025,0.018624946,0.035214756,0.026411066,-0.057852812,-0.062792026,0.029841075,-0.022500858,0.047837187,0.045984983,0.021025954,-0.005750981,0.032653682,0.012645299,-0.023381226,0.03281375,0.029589541,-0.019836884,-0.021437554,-0.021769121,-0.0058481647,-0.010827394,-0.0393079,-0.043583978,-0.0015177788,-0.00022134275,0.018647814,-0.0065113,-0.046876784,-0.004358969,0.022843858,-0.0036129425,-0.02173482,0.009729791,0.04161744,-0.009541141,-0.02533633,-0.022077823,-0.03567209,-0.001837913,0.0023738518,-0.022420824,0.025930865,-0.045253247,-0.012702465,0.02139182,0.07042951,0.007506002,0.013994436,-0.038233165,-0.0024881854,0.04273791,0.05103853,-0.00050378253,0.012908266,0.021243187,-0.009746942,0.027005602,-0.0029112198,0.021689089,-0.021437554,0.01853348,-0.011181829,-0.0075231525,-0.016075308,-0.010781661,0.03029841,-0.020031251,-0.058401614,-0.013251266,0.026159532,-0.007185868,-0.022832423,-0.011622013,0.014840504,-0.002206639,-0.007220168,0.00069028925,0.0061568655,-0.026708335,-0.052547734,0.0036701092,-0.022054955,0.017332977,-0.004101719,0.015229238,-0.043675445,-0.02945234,0.008706505,-0.0051421546,-0.019562483,-0.0263196,0.020545753,0.008449255,0.00083392084,-0.0004280365,-0.0148062045,0.01570944,0.0031355997,-0.011622013,0.020865886,0.014954838,0.023644192,-0.0085521545,0.03210488,0.01961965,0.009318191,0.017573077,-0.015160638,0.008003353,0.01931095,0.031716146,0.0134685,0.022843858,-0.018659247,-0.034780286,0.009209573,-0.047928654,-0.030321276,-0.022603758,0.02240939,-0.022832423,-0.0009711212,0.000114512266,-0.032562215,0.04866039,-0.047562785,0.03343115,0.008289187,-0.008300621,0.021163153,-0.014303136,0.056709476,-0.027028468,-0.02006555,-0.035832155,0.057852812,0.006934334,-0.034185752,0.015046305,-0.024147261,0.006368383,0.024170129,0.023232592,-0.0069286176,-0.032447882,-0.012428065,-0.011690613,-0.013274133,0.003415717,0.015023438,-0.017047143,-0.012096497,0.015800906,0.0036272341,-0.04326384,-0.008392088,-0.008700789,0.02332406,0.0013619993,0.0039502266,-0.010021342,-0.044841647,-0.022706658,-0.017298678,-0.006174016,0.032264948,-0.019059414,0.02125462,0.012062198,0.046785317,0.024147261,0.03393422,-0.009312473,0.0046448032,-0.010324326,0.0070315176,-0.006797134,0.0076317694,0.0154922055,0.011307595,-0.01825908,0.046579517,-0.006825717,-0.0072144517,0.015412172,-0.0051307213,-0.014703304,0.0032928083,-0.005044971,-0.012576698,-0.009089523,0.010055642,0.01445177,-0.015252105,0.06338656,0.022386523,-0.009826975,-0.009358207,-0.050215326,0.018373413,-0.0141202025,-0.024330195,0.013274133,-0.030275542,-0.012485231,0.012953999,-0.014177369,-0.017127177,0.046716716,0.0071287015,-0.008294905,-0.075368725,0.044384312,0.047288384,-0.00950684,0.012748199,-0.012450932,0.0035014672,-0.010267159,-0.025473531,0.023289759,-0.00826632,0.035374824,-0.046327982,0.00404741,0.011513396,0.0051478716,0.0029326575,0.034162886,0.0393765,-0.03295095,0.0063569495,-0.039399367,-0.006002515,-0.019059414,0.004776287,-0.0093810735,-0.0053107967,0.002844049,-0.012736766,-0.10061359,0.03601509,0.017012844,-0.0025081937,-0.009752658,-0.03036701,0.008180571,0.0023681351,-0.05131293,-0.0119707305,-0.0033614086,-0.0015049163,0.0025825107,-0.008929456,0.006900034,-0.036175158,-0.042349175,-0.001246951,-0.0030527078,0.0076889363,-0.027462937,-0.045687716,0.011673463,0.02346126,-0.03455162,-0.0038587598,0.012085064,0.021654788,0.00037122698,-0.055977743,-0.006076832,-0.035557758,0.0068657342,-0.004473303,0.0030184076,-0.0015092038,-0.008283471,-0.0661763,-0.01030146,0.0032470748,-0.020225618,0.014051602,-0.031350277,0.017858911,0.022638056,0.022203589,-0.0061397157,0.005776706,0.029703874,0.008066237,-0.020328518,-0.021197453,0.0064769997,0.007077251,-0.021437554,-0.0046219365,-0.015355006,-0.046236515,0.014508937,-0.010930294,0.07614619,-0.026205266,0.037798695,0.020648653,-0.032356415,0.010244292,-0.007311635,0.005330805,-0.0019165174,0.0023638476,0.024604596,-0.017961811,-0.011261862,-0.0032470748,-0.021300353,0.011324746,0.008655055,-0.023689926,0.026799802,-0.06832577,0.010793094,-0.026868401,-0.0058453064,0.01071306,0.035717823,-0.009272457,-0.035489157,-0.014931971,0.00035139723,0.0072659017,-0.03295095,0.0046562366,-0.016338274,-0.012439498,0.012816799,0.06677084,0.013491367,0.0024395937,-0.03462022,-0.012862532,0.0017593086,0.049529325,-0.053553868,0.013514234,0.00033263938,0.00038230306,-0.025450664,-0.017150043,0.012748199,-0.027668737,0.015114904,-0.013274133,-0.018087579,0.017367277,0.067959905,-0.011959297,-0.017390143,0.013056899,-0.00049449294,-0.03441442,0.032036282,0.0014155932,-0.004050269,-0.006311216,0.020134151,-0.027531536,-0.008369221,0.012256565,-0.013983002,-0.02778307,0.029360874,0.03153321,0.006116849,-0.009609741,0.0069114673,-0.022306489,0.030824345,-0.008472121,-0.020614352,-0.026616868,0.005659514,-0.04971226,-0.013559967,0.011879263,0.01689851,-0.0065799,4.3813e-05,-0.02465033,-0.00459907,0.0046905368,-0.02373566,-0.044933114,-0.035855025,0.0022109265,-0.02465033,-0.0025696482,0.034665953,-0.016258242,0.011181829,0.011107512,0.0005452285,-0.03132741,0.02387286,-0.009529707,-0.011170395,-0.0032670833,-0.02513053,0.025587864,-0.015034871,0.014326002,0.024833262,0.00039730934,0.0034557336,0.020831587,0.04301231,0.036358092,0.004456153,-0.03546629,0.010375776,0.016006706,-0.026937,-0.036678225,0.011050344,-0.04097717,0.03162468,0.012256565,-0.006053965,0.030458476,0.0010354338,0.030252676,0.02139182,0.0004130302,0.012325165,-0.0101185255,0.054011203,0.040451236,-0.0131598,-0.0057881395,-0.0024796105,0.020545753,0.009901292,0.012245131,-0.03237928,0.038118828,0.017641678,-0.017973246,-0.005576622,0.03644956,-0.010009909,0.016441176,-0.00797477,-0.0102099925,-0.011147528,0.029383741,-0.024170129,0.015069172,0.0073173516,0.018144745,0.0058767484,-0.048065856,-0.06096269,-0.016944243,-0.03754716,0.0028926407,0.0053422386,0.050215326,-0.01049011,0.017687412,-0.005170738,0.01183353,0.029703874,-0.047151186,0.021689089,-0.011307595,0.009826975,0.055932008,-0.020545753,0.024421662,0.013834368,0.027943138,0.0023967186,0.0133656,0.06777697,-0.017710278,-0.022295056,0.0075746025,0.008329204,0.012130797,0.027417203,-0.0024295894,0.0077461028,0.0067456835,-0.006111132,0.012450932,-0.0044875946,-0.0036329508,0.010655894,0.01564084,-0.015938107,0.036586758,0.0017921795,0.0015234955,-0.016749876,-0.0005973932,0.01186783,0.0054422803,-0.025862265,0.0066942335,-0.0040674186,0.010930294,0.02359846,-0.0043789777,-0.024535995,0.027897405,0.014771904,-0.0396509,0.025153397,0.030389877,0.009969892,0.017218644,0.017447311,0.04797439,-0.005708106,-0.006848584,0.0131598,-0.0040416936,-0.01849918,0.024078662,0.0030326992,0.04063417,0.0005673806,-0.015480773,0.0064769997,-0.03628949,0.028171804,0.022397956,-0.0019279507,-0.0085521545,0.017127177,0.019539615,-0.0037415677,0.016635543,-0.015206371,0.010827394,0.0049963794,-0.0021308928,-0.017790312,0.05863028,0.02876634,0.009392507,-0.0066942335,0.006711384,-0.009798392,-0.008049087,0.005245055,0.005176455,-0.02485613,-0.004356111,-0.01853348,0.016406875,0.007248752,0.00928389,-0.0019794009,-0.02890354,-0.025930865,-0.02910934,0.00044625843,0.004121727,0.005145013,0.01186783,0.045824915,0.015183505,-0.008392088,-0.029703874,-0.0038844848,0.0044189943,0.024055794,0.009998475,0.021174587,0.008872289,0.019585349,0.009746942,0.0005391545,0.008020503,0.024764663,-0.011416212,-0.02485613,-0.019528182,-0.01931095,-0.00010620522,0.0063512325,0.02401006,-0.0016321124,-0.047791455,0.007986204,-0.0041846107,-0.021368954,-0.008140554,0.018693548,-0.033339683,-0.023244025,-0.02234079,0.0015206372,0.020728685,-0.045459047,0.051907465,0.009415374,-0.013136934,-0.013971569,0.049117725,0.0026711193,0.01961965,-0.01448607,0.024398794,0.014817637,-0.027531536,-0.00037730095,-0.009375357,-0.02203209,-0.011742063,-0.016784176,0.0036558176,0.00035175454,-0.005436564,-0.014245969,-0.008151988,-0.011279012,-0.011170395,-0.023038225,0.030115476,-0.012931133,0.01853348,-0.034643088,0.015892373,-0.008969473,0.0064255497,0.034048554,0.031373147,0.016041007,0.028720606,-0.0034300087,0.018053278,-0.009929875,-0.03029841,-0.010375776,-0.03295095,0.020934487,-0.004073135,-0.03777583,0.022866724,-0.0054822974,0.03370555,-0.011364762,-0.0020851595,0.01217653,-0.013514234,0.032905217,0.021711955,0.009918442,-0.007969053,-0.020854453,0.008054804,-0.020591486,0.034162886,-0.0062311823,0.036906894,0.00019079424,0.017653111,0.0016678417,-0.004390411,0.003610084,-0.04349251,-0.014691871,-0.021791989,-0.026868401,0.02346126,-0.03720416,0.024421662,-0.0121650975,-0.034665953,-0.007877586,0.019002248,0.01751591,0.014920537,0.002249514,0.017813178,-0.051358663,-0.025244864,0.0786158,0.013411334,-0.00229096,-0.011158962,-0.012953999,0.017527344,-0.008329204,0.017470177,-0.0047448454,-0.047699988,0.01574374,-0.007082968,0.023415526,-0.022112122,-0.013662868,-0.041228704,-0.025313463,0.015480773,-0.0022209305,-0.00785472,0.0065456,0.03601509,0.0062997825,-0.00012273,-0.00012326594,0.011370479,0.018590648,-0.006002515,0.047882922,0.02465033,-0.023849994,0.0072030183,-0.024124395,0.053508136,0.008071953,0.018750714,-0.038004495,-0.012530965,0.011947864,-0.0119707305,-0.045298982,0.016441176,0.023312626,-0.03114448,-0.0112447115,-0.02533633,0.0005370107,-0.013308434,0.00782042,0.0021208888,-0.015046305,-0.005430847,0.009329624,-0.0031756163,-0.0059281983,0.03482602,0.038507562,0.023083959,0.03832463,0.019642517,-0.015103471,-0.015206371,-0.001905084,-0.0071458514,-0.029338008,-0.026754068,0.004338961,-0.014886238,-0.008403521,0.015377873,-0.003138458,0.004307519,-0.043378178,0.006997218,0.038759097,0.027051335,-0.0011819238,-0.0020251344,0.008129121,-0.011702046,-0.0028240404,0.010152826,-0.0036443842,3.492535e-05,0.014703304,-0.010953161,0.023918593,0.0025310605,-0.012542399,-0.029292274,0.0045619113,0.008969473,-0.02094592,-0.003129883,0.007706086,-0.032425016,-0.019711116,0.008723656,-0.0010711631,0.031350277,0.001057586,-0.021551888,-0.02074012,0.028697738,-0.02006555,0.019733984,0.0031012995,0.020831587,-0.010398643,-0.03706696,0.015457906,-0.04175464,0.024330195,-0.0035271922,-0.011301879,0.02826327,-0.009758375,0.0031184496,-0.004121727,0.008580739,-0.005122146,0.007454552,0.034460153,-0.03770723,-0.05145013,0.03434582,-0.0043732612,0.003315675,0.05382827,-0.015732307,-0.006368383,-0.0010325755,0.010484393,0.0055280305,0.04321811,-0.027485803,0.014234536,0.029017873,-0.01061016,-0.007300202,-0.007900453,0.014646137,-0.013880102,0.024078662,0.016464042,-0.0077175195,-0.016041007,-0.01836198,-0.047837187,0.025907999,-0.011753497,0.00027850957,0.0034014252,0.020580051,-0.003510042,0.0039016348,0.0078032697,-0.0075174356,0.00799192,-0.02098022,-0.01707001,-0.002232364,0.025107663,-0.03679256,-0.015446472,0.0011590571,-0.01724151,0.0030326992,-0.006797134,0.055657607,0.0043532527,-0.006825717,-0.014268836,0.0388277,0.038073096,0.0007453123,-0.012668165,-0.017641678,-0.021894889,0.007986204,-0.015858073,0.027005602,0.026411066,0.020317085,-0.011381912,0.04893479,-0.011604862,-0.014577537,-0.015663706,0.015675139,0.043332443,0.023827126,0.0015463622,0.008397805,-0.012313731,0.025770798,-0.002986966,-0.029223673,0.0077689695,0.030938677,-0.01025001,0.029017873,-0.0053393804,-0.01448607,-0.036746826,0.0017678837,0.022260755,0.007534586,0.01557224,0.034643088,-0.0132627,0.008752239,0.0102614425,0.013800068,0.03720416,-0.0053593884,0.01173063,-0.0025110522,0.004790579,-0.002275239,0.002165193,0.0021866306,-0.011473379,0.011879263,-0.03587789,0.05478867,0.008134837,-0.020591486,-0.003964518,-0.03414002,0.013445634,-0.0114390785,0.026479667,0.012222264,0.010878844,-0.004810587,-0.00090323563,-0.025427798,0.021437554,-0.009329624,0.00044054174,-0.026776934,-0.0065284497,0.038004495,-0.005396547,0.067045234,0.05890468,-0.016303975,-0.0054479972,-0.00919814,0.030984411,-0.0010775944,0.01577804,-0.032630816,0.004278936,-0.019402416,-0.026754068,0.012119364,-0.0012276573,-0.030961545,0.01564084,0.027165668,0.008895156,0.041274436,-1.5720872e-05,0.00404741,-0.0009389649,0.040611304,-0.012302298,-0.015823774,-0.0033499752,0.021940622,-0.032630816,-0.042463508,-0.028652005,0.0038244596,0.0066656503,0.00085392926,-0.025382064,-0.0030498493,0.0031355997,0.0013691451,-0.039879568,-0.04141164,-0.03441442,2.7779497e-05,0.008935172,0.015469339,0.0077918363,-0.024970463,0.009261023,0.0031441746,-0.020820152,0.027394336,1.31081715e-05,-0.0065513165,0.0023152558,-0.009409657,0.0008903731,0.021620488,0.018407714,0.019974085,0.024192994,-0.03169328,0.023941461,0.009552574,0.034437288,0.01176493,0.0062654824,-0.019631082,-0.007168718,0.025176264,0.018865047,0.031190213,-0.031464614,-0.0036901177,0.009535424,0.037112694,-0.01179923,0.0020308509,0.019733984,0.0055851974,0.037478562,-0.026502533,0.005433705,0.019802583,-0.02435306,-0.020214185,0.027119935,-0.004307519,0.047242653,0.015926674,0.009261023,-0.031396013,0.023129692,0.0053165136,0.01455467,0.024192994,0.00785472,-0.018442012,-0.030001143,0.015217805,-0.036403824,0.01618964,0.00945539,0.021025954,0.006505583,0.036632493,0.025702199,0.009438241,-0.03546629,0.033957087,0.0057709897,0.025999466,-0.01042151,-0.024467396,0.0013512805,-0.052273333,-0.01570944,0.03029841,0.010781661,0.02373566,0.01822478,0.013868668,-0.030138344,-0.029338008,-0.021460421,0.015903806,-0.001329843,0.0055080224,0.031007279,0.023552727,-0.0060139485,0.014337436,-0.031784747,-0.029681008,-0.034734555,0.045184646,-0.03050421,0.04998666,0.008643622,0.025107663,0.012062198,0.0061911657,0.012782499,-0.0027397193,-0.042029038,0.004933496,-0.012290864]	2025-08-06 10:23:30.428393-04	0
ads	2ef027c4-d5de-406a-94b0-9b79c665427e	[-0.025346452,-0.023216598,0.0013363076,-0.0096196495,-0.0020180673,-0.037184212,0.016556388,0.03558388,-0.006942622,0.022169322,0.022286993,-0.038737476,0.019698218,0.013755805,0.019003956,0.01882745,-0.0021136752,0.023557846,-0.007701603,0.007707487,0.0002667835,-0.0075192126,0.025228782,0.01774487,0.037372485,-0.019251067,-0.04024367,0.012896802,0.014638342,0.02461689,0.008266427,-0.015026658,0.00939019,0.009519629,0.0056923614,-0.039937727,0.021275017,0.010266843,0.0224635,0.0077722063,0.0019268717,0.026687909,0.003165365,0.013438092,-0.0029094291,0.036854733,0.0048098247,0.026028948,-0.01139649,0.050692905,-0.039443504,0.02151036,-0.026970321,0.013591065,-0.044879932,0.0002916048,-0.057988543,0.015367906,0.010107987,-0.014226491,0.044526916,-0.0011995144,-0.010408049,0.06085973,-0.07074414,-0.0043979743,-0.040055398,0.004906904,-0.021816306,-0.05841216,-0.030123917,-0.012920337,0.011914245,-0.0505517,-0.011896594,-0.0505517,-0.025417056,0.0104963025,0.017438924,0.0111081945,-0.01675643,0.015767988,-0.023275433,-0.06053025,-0.012767363,-0.015615015,-0.02821764,-0.012849734,-0.03897282,-0.042573567,-0.041891076,-0.020239508,-0.030806413,-0.01973352,0.06462522,0.033324584,-0.015732687,0.006142455,0.0022401724,0.03259502,0.0084370505,-0.027158596,0.007372123,0.022557637,0.004650968,0.04236176,0.038925752,-0.019992398,-0.029182546,0.015626783,-0.09361949,-0.006107154,-0.046597935,-0.0011980436,0.02581714,-0.039702382,0.06895553,0.003986124,-0.0135204615,-0.03817265,-0.029723834,0.024381546,0.017062375,-0.027370404,-0.027935227,-0.0051657814,-0.030853482,-0.036548786,-0.022145787,-0.0075486302,-0.056623552,0.027558679,0.0673552,0.009043059,-0.040879097,0.038831614,-0.017050609,-0.00633073,-0.026570238,-0.0018371472,0.007189732,0.0073485887,-0.012673226,0.044644587,-0.08208768,-0.032124333,-0.051022388,-0.033018637,-0.045562427,0.028876599,-0.077286676,-0.025958344,-0.026711443,0.012837967,0.022334062,0.029064875,0.0037243047,-0.031324167,-0.04777465,-0.015250234,-0.039490573,0.009778506,-0.021828074,0.030100385,-0.023640215,-0.016626991,-0.013461626,-0.0034948452,-0.050692905,0.008890086,0.019003956,-0.02159273,-0.024122668,0.008684161,0.036172237,-0.025205247,0.03612517,0.022687076,-0.051728416,0.026099551,-0.01965115,0.008013433,0.009125429,0.04699802,0.028123502,-0.011119962,-0.0047921743,-0.011172914,-0.0060836193,0.0021710403,0.039702382,-0.050457563,0.002644668,0.04160866,0.030665208,-0.032242008,0.026123086,-0.0047039203,-0.02850005,-0.027229197,0.0034330676,0.00035650804,-0.014626575,-0.005027517,0.03198313,0.0063189627,-0.0038419764,0.0009906474,0.0034242424,0.00730152,0.053846505,-0.039114024,0.029135477,0.0005993895,-0.04125565,-0.018215558,0.030053316,0.0028329426,0.010019733,-0.0024166796,-0.067166924,-0.0016268092,0.011943663,-0.017580131,0.03259502,0.013567531,0.058223885,-0.0050392845,-0.011914245,-0.03181839,0.02478163,0.009201916,-0.050316356,0.016779963,0.06354264,0.009031292,-0.021063209,-0.0036713525,0.020992605,0.013202748,0.00013192084,-0.012496719,0.055823386,-0.0058188583,-0.013767572,-0.0062130583,-0.004071436,0.015238467,0.022934185,-0.019333437,0.045727167,0.00021015404,0.11277642,-0.009090127,0.0030712276,-0.012437884,-0.014650108,0.06373092,0.021863375,0.0065837237,-0.026193688,-0.011302353,-0.027558679,-0.023134228,0.059212327,0.028570654,0.027888158,0.044362176,-0.052387375,-0.0022210507,0.052057896,-0.0051510725,0.0489043,0.0264761,0.012437884,-0.017509528,0.0036184003,0.053564094,-0.024263876,0.037348952,-0.048574816,-0.010849318,0.016509319,0.020263042,0.017556597,0.017368322,-0.02718213,0.00016262577,-0.012767363,-0.07521566,0.021710401,-0.03160658,0.018392064,-0.00046002225,0.023251899,-0.012179006,0.028194105,0.020910235,0.010713995,0.07013225,0.038525667,0.025158178,0.04546829,-0.025887743,-0.027982296,0.042502966,-0.06646089,-0.024287408,0.036595855,0.009884411,0.024310943,0.013626366,-0.008548838,-0.046174318,-0.04349141,-0.077757366,0.0079545975,-0.008807716,0.03379527,-0.005156956,0.012379047,0.003147714,0.0045185876,-0.043303132,-0.07046173,-0.003509554,0.01435593,0.061801102,0.044950534,0.01637988,0.002896191,0.0059688897,-0.01703884,0.014697177,0.030429864,-0.04306779,0.0071132453,0.06923794,-0.017603666,0.00042913345,-0.0009832929,-0.00021383128,-0.05191669,0.07281516,-0.0096196495,-0.021475058,-0.022428198,0.011172914,0.038690407,-0.00860179,-0.03781964,0.017533062,0.025746536,-0.006071852,-0.010213891,-0.022110485,-0.020404248,0.03626637,-0.0032094917,0.012320212,-0.04367968,0.025958344,0.0077839736,0.0076427674,-0.020357179,0.0065837237,-0.044526916,-0.01129647,0.039208163,-0.013849942,-0.020580756,0.009984432,0.038619805,-0.019015724,-0.04379735,-0.016309278,-0.009549047,0.02076903,-0.0119848475,0.024358012,0.012755597,0.028735394,-0.010725763,0.016450483,0.04612725,-0.0021519186,0.026381962,0.012837967,-0.018497968,0.032524418,0.046433195,-0.027699884,-0.011761272,-0.024122668,0.021192648,0.0050245756,0.045444753,-0.004795116,0.042761844,0.044385713,0.03165365,-0.01189071,0.012543788,0.03259502,-0.008731229,-0.022075184,-0.0005409214,0.039278764,0.03784317,0.0032271424,0.053375818,-0.016368113,0.01790961,0.009584349,-0.006107154,0.0008656214,-0.019498177,0.0208867,0.031488907,0.019592313,-0.024758095,-0.026852649,-0.04695095,-0.009349005,0.011343538,0.010461002,0.007742788,0.0066837445,-0.012567322,-0.054552533,-0.007495678,0.014167655,0.012096636,-0.025934812,0.003565448,-0.0011995144,-0.022816515,0.033865873,0.04895137,0.021851609,-0.036878265,-0.019968864,-0.04360908,-0.019533478,-0.009378423,-0.061000936,-0.033112776,-0.0070602936,-0.054411326,-0.0113729555,-0.004359731,0.0011421496,0.0025534728,0.026617305,-0.014473601,-0.009684369,0.009955013,0.0032771528,0.031630114,0.034807246,0.024240341,0.03040633,-0.048998434,-0.0014150004,0.03351286,-0.040267207,-0.046503797,0.04852775,0.00682495,0.014261792,-0.03744309,0.028570654,-0.020074768,-0.015332604,-0.030924086,-0.035725083,0.02440508,-0.06283661,-0.055964593,-0.03400708,-0.061942305,-0.016991772,0.037254814,0.043303132,-0.029723834,0.055635113,-0.046433195,-0.06274247,0.011008174,0.0001853327,-0.024358012,0.011137613,0.064672284,-0.010725763,-0.026028948,-0.022416431,-0.013626366,0.020957304,0.0014297094,-0.033606995,0.015779756,-0.04716276,-0.036595855,0.04946912,-0.014908986,-0.00032469994,0.0907483,0.010531604,-0.003833151,-0.00738389,0.01427356,0.0077251378,0.018898051,0.033112776,-0.0042891284,0.007566281,0.0006788178,0.037207745,-0.033771735,-0.0061895237,0.02659377,-0.0056247003,0.023216598,0.010408049,0.013685202,-0.06297781,-0.03247735,-0.02680558,-0.01795668,-0.0120378,-0.010455118,-0.016521087,0.02767635,-0.01807435,-0.07394481,-0.047256898,0.014532438,0.022475267,-0.021463292,-0.021498593,0.0057188375,0.012049567,0.05638821,-0.0009957956,0.0014870743,0.016062167,0.005283453,0.016897636,0.011225866,0.023816723,0.058270954,-0.026005413,0.026687909,-0.010684577,0.016062167,0.008901853,0.006689628,-0.010019733,-0.009349005,-0.004362673,0.0034889616,-0.018898051,0.019839425,-0.0059688897,-0.0084194,0.05097532,0.033230446,-0.031277098,0.00889597,0.028523585,-0.025369987,-0.001868036,-0.006507237,-0.008495886,0.013897011,4.247208e-05,-0.007995782,-0.022969488,-0.004142039,-0.00078104495,0.03106529,-0.0038272673,0.017380089,0.06354264,-0.011261168,-0.019498177,0.018733311,0.020451317,0.0023902035,0.02511111,0.020345412,0.03810205,-0.02838238,-0.025369987,-0.020110069,-0.013744038,0.013026241,0.0044832863,-0.0063424967,0.012461417,0.012708528,-0.021580962,-0.0049980995,-0.003624284,-0.013779339,0.019003956,0.014744246,-3.010737e-05,0.01274383,0.015403206,0.0007788386,0.024640424,-0.024428615,-0.025958344,0.027652815,-0.0150972605,-0.018050816,-0.0016253383,0.04591544,-0.017521294,0.0035448556,-0.02461689,0.04144392,0.0032153754,0.007595699,0.013132146,0.0046480265,-0.015050192,-0.006983807,-0.0059071123,0.009319588,0.053517025,0.03657232,0.008184057,0.024428615,0.0073485887,0.037325416,0.01770957,0.018427366,-0.04203228,-0.019321669,0.026946787,-0.0111552635,-0.005280511,0.025793605,-0.00032120658,0.018709777,-0.0006810241,-0.016709361,-0.01036098,-0.014202957,-0.001950406,-0.0045274133,0.039984796,0.0077310214,-0.028452981,-0.017944911,0.013555763,0.004865719,4.9642687e-05,-0.02188691,-0.044738725,-0.008078152,0.0020445434,0.0001939742,-0.0075427466,-0.034571905,0.0133910235,-0.014732479,0.025369987,-0.049751535,0.023381338,-0.007607466,0.0025711234,-0.017497761,-0.016732896,0.03821972,-0.0070426427,-0.020510152,-0.024428615,-0.003680178,0.049751535,-0.04546829,-0.00051113585,0.042055815,0.04596251,0.005221675,0.010096219,0.028194105,-0.010084452,0.0019577604,-0.03909049,-0.0050951783,0.0057453136,-0.016944705,0.018462667,-0.0054893782,0.028523585,0.002129855,-0.06519004,0.0028049957,0.023240132,0.0120731015,-0.009672602,-0.012955639,-0.033253983,-0.035678014,-0.004274419,0.03800791,0.010808133,-0.035678014,0.018215558,-0.029770903,0.0025461183,-0.026876183,0.0041332133,0.007330938,0.046362594,0.016626991,-0.05732958,-0.020392481,-0.0037272465,-0.010861085,-0.008901853,-0.029794438,-0.03177132,0.018850984,-0.0071014785,-0.026381962,0.016532853,-0.009654951,-0.032948036,-0.0055099707,-0.012602624,0.019415807,0.010878735,-0.04918671,0.006954389,-0.0505517,-0.03956118,0.010125637,0.005477611,-0.014285327,0.013661668,-0.04099677,-0.008460585,0.026664374,0.041632198,0.019886494,-0.024122668,9.900958e-05,0.007472144,-0.009278402,0.0011892181,-0.02746454,-0.006336613,-0.014026449,-0.007095595,0.019356972,0.060906798,-0.015850358,0.033818804,0.009731438,0.009878527,-0.011096428,-0.020757262,0.00666021,-0.029159011,-0.008184057,0.02821764,0.012520254,0.023263667,-0.030123917,-0.009119545,-0.003927288,-0.028358845,-0.029229615,-0.023028323,0.0017474226,-2.2775881e-05,-0.009496095,-0.013708736,-0.015120795,-3.939239e-05,0.0030829948,-0.023275433,0.040643755,-0.0104963025,0.019062793,-0.022898884,0.0038066749,-0.0054217167,0.008807716,0.016991772,0.013296885,-0.004115563,-0.0069720396,-0.035066124,-0.0056688273,-0.009443142,0.02941789,-0.0075780484,-0.01220254,0.03974945,0.044362176,-0.014250025,0.0023651982,0.048716024,-0.012849734,0.019545246,-0.013955846,-0.0037978494,-0.029982712,0.036878265,-0.010107987,0.03668999,-0.00024784572,0.015603248,0.0008237009,-0.013132146,0.0505517,-0.040526085,0.03214787,-0.00236814,0.031206496,-0.03219494,0.040973235,-0.025581796,-0.012461417,-0.0070720604,-0.0062660105,0.016450483,0.0010274198,-0.015920961,-0.029111942,0.013897011,-0.027135061,-0.019203998,-0.022781214,0.022945954,-0.016485784,-0.04125565,0.005768848,0.015650317,-0.029841507,-0.013614599,0.010466885,0.010602207,0.038690407,0.061754033,-0.03275976,0.0018871576,0.015838591,-0.036901798,0.045444753,-0.017580131,-0.00018514883,-0.017074144,-0.050410494,0.019992398,0.01476778,0.0079545975,0.022604706,-0.008907737,0.00044163605,-0.036972404,-0.0272998,-0.008325263,0.019509943,0.0007979602,-0.02080433,-0.0065307715,-0.041891076,0.027229197,-0.00088400755,-0.0031859574,-0.015673852,0.02659377,-0.017780172,0.0049627977,0.029488493,-0.020098303,-0.00051187124,0.012131938,-0.010484535,-8.19564e-05,-0.022086952,0.038643338,-0.013296885,0.0160151,1.8087405e-05,0.015709152,0.004724513,0.012567322,0.012167239,0.02478163,0.0033977663,0.041891076,0.0008509124,0.03024159,0.0118554095,-0.006407216,0.020427782,-0.029559094,-0.04120858,-0.019957095,0.030218055,0.01787431,0.023852024,-0.008319379,0.022369362,-0.024193272,0.00085532514,-0.006689628,-0.044785794,0.0031388889,-0.016980005,0.03259502,-0.0023990287,-0.019745287,-0.053140476,-0.0060542016,0.00036128846,-0.0032153754,0.05092825,0.004336197,-0.024122668,-0.024546286,-0.0008384098,0.013426324,-0.016426949,0.0256524,-0.00657784,0.0028903077,0.0031271216,-0.009525512,0.008795949,-0.017780172,0.020922003,0.013567531,-0.018556803,-0.01332042,-0.04346787,-0.04174987,0.015791522,-0.007272102,0.031912524,0.03424242,-0.007130896,-0.038643338,0.012473185,-0.0031388889,0.039372902,-0.005407008,0.029700302,0.0009141609,-0.023863792,-0.001868036,0.014285327,0.0057600224,0.014803082,-0.06730813,-0.0038096167,0.030806413,-0.0020180673,0.029017806,0.0011480331,-0.01593273,-0.024122668,0.0075015617,0.012331979,0.018439133,0.033159845,0.021157345,-0.019851191,0.0070602936,0.030218055,-0.007095595,0.015309069,0.0051157707,0.024193272,0.017462458,0.03205373,0.03396001,-0.01460304,0.021710401,0.021733936,0.026546704,0.014014683,0.020416016,-0.026687909,0.0018356763,0.045280013,0.016556388,0.013226283,-0.0032477349,-0.039208163,0.042644173,0.006424867,0.017568363,-0.016932936,0.029064875,0.04174987,0.039890658,-0.0360781,0.010455118,0.0063895653,-0.011084661,-0.020345412,-0.027699884,-0.02180454,-0.019309903,0.05732958,-0.020239508,0.03433656,-0.04017307,-0.0021636856,0.012708528,-0.004812767,0.013779339,-0.020368947,-0.010072685,-0.0017150629,0.0115494635,0.035301466,0.028829532,0.009907945,-0.014650108,-0.013638133,0.038949285,0.017521294,0.0057600224,-0.026570238,0.009772623,-0.021122044,-0.0033536393,0.009119545,0.012802665,0.03440716,-0.0017709569,0.019098094,-0.0036301676,-0.004862777,0.025040507,0.025699468,0.0016959413,-0.04360908,-0.005227559,-0.036548786,0.03749016,-0.0035007289,-0.009837342,-0.030618139,0.025228782,0.025417056,-0.013285119,-0.012990939,-0.017497761,-0.002896191,0.012720295,-0.022887118,0.008672394,0.017450692,-0.04323253,0.017674267,0.03438363,0.0040596686,0.021698635,0.013367489,-0.004421509,-0.015544413,0.016285744,0.037043005,-0.023134228,-0.00073471176,0.0037919658,-0.069520354,-0.021863375,0.024358012,0.010219774,0.018180255,0.018721545,-0.046550866,-0.017450692,-0.015226699,0.001504725,0.03548974,-0.011343538,0.0082193585,-0.006995574,0.0012156942,0.024334477,0.004347964,-0.03958471,-0.012214308,0.014732479,0.012767363,0.031747784,0.046174318,0.04285598,0.031253565,0.015344371,-0.02664084,-0.014967822,-0.050457563,0.037137143,0.014167655,-0.042761844,0.0046068416,0.02374612,0.0046450845,0.04895137,-0.0037331302,0.0061718733,-0.007454493,-0.0066425595,-0.002857948,0.04339727,0.017839007,0.029135477,-0.0013841117,0.017356554,-0.0072014993,0.017980214,-0.001198779,0.0028932493,-0.018439133,-0.008984223,0.007525096,0.007472144,-0.01100229,0.0041949907,-0.0014473601,-0.00061262754,-0.0071661975,-0.036454648,0.0031418304,0.00068690773,0.007936946,0.013767572,-0.01323805,-0.011825992,0.0007413308,0.012837967,0.0133910235,-0.008595907,-0.015462043,0.05634114,-0.012532021,0.0032653857,0.016556388,0.010896386,0.044479847,0.027535144,-0.018709777,0.024122668,0.0011575939,-0.009790273,-0.02369905,0.026052482,0.0046480265,-0.037631363,-0.04723336,0.00010627212,-0.033536393,0.0147913145,-0.0256524,-0.015709152,0.018192023,-0.01629751,-0.038337395,0.034030613,0.025793605,-0.0070308754,-0.006548422,0.03548974,-0.007936946,0.009437258,0.0025137586,0.020180672,0.030500468,-0.009702019,0.017897844,-0.04518588,0.0020460142,-0.009678486,-0.01547381,-0.026287826,0.026452566,0.012096636,-0.00045524182,0.010125637,-0.03219494,-0.029323751,-0.014591273,-0.0055511557,-0.014967822,-0.0073662396,-0.016521087,0.010814016,-0.0021666274,0.0023902035,-0.00947256,-0.003997891,0.011596532,0.020321878,-0.015297302,-0.029064875,0.050128084,-0.030759344,0.014026449,-0.042455897,0.0045950743,-0.019062793,0.005351114,-0.029111942,0.029912109,-0.0050951783,0.024852233,0.00172683,-0.016250443,0.04770405,0.00081266917,0.019051025,-0.018639175,0.0072191497,-0.015697386,-0.01712121,0.03789024,-0.012008382,0.0056247003,0.026170153,0.0005685007,0.0050628185,0.022310527,0.038902216,0.025346452,-0.050787043,0.0047068624,0.012355513,0.039043423,0.033136312,-0.0122496085,-0.00545996,0.028288241,0.002882953,0.0016459309,-0.007995782,4.5597728e-05,-0.019686451,-0.011861293,-0.017556597,-0.020698426,0.013085077,-0.01177304,-0.011937779,0.018580338,-0.008072269,0.0009729967,0.034995522,-0.001963644,-0.023816723,-0.030265125,-0.0018415599,-0.021074975,0.0034566019,-0.025581796,0.0042097,-0.029323751,0.018309694,-0.0055540972,-0.016815266,0.0017474226,-0.0052481513,-0.030453399,0.010213891,-0.0029991537,-0.028853066,0.002509346,0.0037743151,-0.0055923406,0.0071603144,-0.009013642,0.010613974,0.00086635683,-0.00018009264,0.014908986,-0.009984432,0.035889823,0.008925388,-0.019356972,0.0417028,0.010690461,0.0042391177,0.015262001,-0.01547381,0.013673435,0.008036967,-0.0022254633,-0.004765698,0.017768405,-0.025464125,0.018792147,-0.018592106,0.020168904,4.0817322e-05,-0.004862777,0.00028002154,-0.023628449,-0.025864208,-0.03925523,0.004124388,0.014367697,-0.011031709,0.015367906,0.0005104004,0.015567947,-0.020922003,0.0055158543,0.0043126624,0.0052187336,0.028311776,-0.03454837,0.0046745026,0.0027196838,-0.014473601,0.018462667,0.022640007,-0.024805164,-0.029959178,0.015309069,0.019356972,-0.0066249087,-0.0062483596,-0.012237842,-0.030688742,0.0058394508,-0.0056688273,0.040573154,-0.008054618,0.022028115,-0.020298343,0.054223053,-0.013802874,-0.028758928,0.009066593,0.02014537,0.0035330884,-0.010066802,0.04756284,0.017650733,-0.0022931243,-0.01373227,0.02295772,-0.011167031,-0.009490211,-0.0033801154,0.027252732,-0.0393023,0.012696761,-0.004795116,0.004874544,-0.017674267,0.03838446,0.009590232,-0.015403206,0.004821592,0.014250025,0.0076368838,-0.0058600437,-0.036831196,-0.019639382,0.025299385,-0.02821764,0.014532438,0.0015547355,0.012990939,0.0017930203,-0.01894512,-0.0041096793,-0.0114612095,-6.8166766e-05,0.036501717,-0.038502134,-0.04666854,-0.02821764,-0.0028741278,-0.025723003,-0.0010833137,-0.018921586,-0.03619577,-0.018509736,0.021486826,-0.003233026,0.017403623,-0.026970321,-0.015356138,0.024052067,0.038337395,-0.014885452,0.026452566,-0.02817057,0.002760869,-0.0028903077,0.005045168,-0.020074768,-0.01886275,0.0037419554,-0.007883994,0.012014266,-0.015391439,0.034148287,0.025181713,0.022192856,0.00818994,0.013873477,-0.0022887117,-0.016403414,0.0041096793,0.023934394,-0.018921586,-0.009178381,-0.0044509266,0.009996199,0.021439757,-0.0003721363,-0.028052898,-0.018650942,0.0049451473,0.0044097416,-0.05568218,-0.009566697,0.008690044,-0.009631417,-0.0037890242,0.0025064042,0.0015488518,0.00069095264,0.0063601476,-0.019992398,-0.008548838,0.0360781,0.02920608,-0.009125429,0.016579922,-0.02871186,0.017156513,0.0057806154,-0.0075839316,-0.010719879,0.009366656,0.028147036,0.010655159,0.010449234,-0.03558388,0.029606164,0.023393106,-0.015838591,0.009213683,0.010249193,-0.006218942,0.011102311,0.030335726,0.01468541,0.009860876,-0.0014326512,-0.03351286,-0.0064719357,-0.0010465414,0.006160106,0.017391857,-0.01675643,-0.031418305,-0.015650317,-0.007701603,0.03817265,0.054175984,0.028052898,0.052152034,0.033418722,-0.027111527,0.029559094,-0.0601537,-0.033253983,0.0023593146,0.010078569,-0.0112435175,-0.01812142,0.07046173,0.023899093,-0.015038425,0.033748202,0.020733729,-0.010761064,-0.01820379,0.019309903,-0.00424206,-0.040314276,-0.007360356,0.011249401,0.012131938,-0.007701603,-0.009519629,0.029888576,0.0016679943,-0.034971986,0.011161147,0.01712121,-0.0020268925,0.017721336,0.010708111,-0.035160262,0.047751117,-0.029111942,0.015579714,-0.0075839316,-0.016626991,0.016862335,0.014956054,0.020510152,-0.007995782,-0.0041273297,-0.0035889824,-0.0505517,0.026334895,0.0040479014,-0.014567738,0.017262418,-0.05092825,0.031159429,0.012437884,-0.00046002225,0.02473456,-0.025252316,-0.017191814,0.012473185]	2025-08-06 10:23:30.428393-04	0
ads	a95548d4-c7a5-4897-8bb1-bfc4cd438ee4	[-0.01745337,0.001566158,0.045206223,0.025722155,-0.029385373,-0.00156284,-0.0052957376,0.037906334,0.004141028,0.051178858,0.0713531,-0.035915453,9.866257e-05,0.01177273,0.052320298,0.006613036,-0.038808864,-0.016617203,-0.05423154,0.038384143,0.012841169,-0.0012343449,0.00143841,0.005318965,0.0001977399,-0.029013742,0.026306147,-0.0015703057,0.03987067,-0.029757002,0.043852426,-0.039153952,-0.0579213,-0.018316086,-0.01539613,0.0003695569,0.0020804685,0.03426966,-0.038277965,-0.0031389524,-0.07161855,-0.0024852804,0.0563286,-0.0054948255,-0.00026399884,0.014838683,-0.0060754986,-0.017971,0.010870199,0.0145865055,-0.03695071,0.04066702,0.042020816,0.016577385,-5.80673e-05,0.020200783,0.014825411,0.006125271,0.040693562,0.0029166376,0.00021153087,-0.018687716,0.032331873,-0.018103724,0.012476174,0.012967258,-0.0413041,0.04215354,-0.022510204,-0.013816699,0.040109575,0.011706368,0.023479098,-0.012628809,0.008262147,-0.004980515,0.02118295,0.026146876,0.021090044,-0.030712625,-0.0074923406,0.031243525,-0.044356782,-0.017639186,-0.01734719,-0.023107467,-0.09396948,-0.0032252239,-0.008713413,0.011109104,-0.040428113,-0.004233936,-0.014267965,-0.0069481675,-0.008441326,0.0036499447,-0.042657897,-0.012675262,0.0938633,0.013385342,0.046002574,-0.033393674,-0.0073264344,0.019245163,-0.036419813,0.011241829,-0.00227292,0.017254284,0.008806321,-0.02116968,-0.02543016,0.040481202,-0.052214116,0.039392855,0.036685262,0.02779267,0.046321116,-0.0024935757,-0.014214875,-0.03567655,-0.032252237,0.004160937,-0.004081302,-0.07687447,-0.02128913,-0.022988014,0.039313223,-0.04215354,-0.026611414,-0.015581945,0.013391978,-0.007651611,0.0023044422,-0.001967652,-0.047595277,0.016378297,-0.03084535,0.0068552596,-0.08181185,0.036658715,0.03384494,-0.0061816787,0.02700959,0.06360194,-0.08600597,-0.005783503,-0.040773198,-0.016338479,-0.010027394,0.0062414054,-0.03466784,0.009576127,-0.0028900926,-0.011706368,-0.060097996,-0.02443472,0.0563286,-0.0028900926,-0.04257826,0.00015989246,-0.0053621004,-0.031296615,0.026306147,0.020386599,-0.004525931,-0.04488768,0.005046878,-0.0061816787,-0.078042455,0.047462553,0.013026984,-0.0013314002,-0.047276735,-0.030712625,0.00788388,0.011746185,-0.022656202,-0.050302874,0.028297026,-0.013378706,0.043109164,-0.029730458,-0.020174239,0.016524294,-0.03089844,-0.02175367,0.027261768,0.03652599,-0.009947758,-0.029810093,0.009423493,-0.03105771,0.080962405,0.0490818,-0.010306116,-0.020001696,0.04778109,0.0071273465,0.0228022,0.028881015,0.0074127056,-0.029226102,-0.001388638,0.034588203,0.0018598126,-0.0022845336,-0.024647081,0.024647081,-0.020691868,0.011155558,0.063389584,-0.024248905,0.010777291,0.016789746,-0.051842485,-0.04775455,-0.03052681,-0.0051596942,0.044569142,-0.009065135,0.010312753,0.006589809,0.02874829,0.042525172,-0.03652599,0.034986377,-0.016431388,-0.014652869,-0.004107847,-0.030394085,0.0051961937,-7.7250246e-05,0.0036200813,-0.026598142,0.010525113,0.008501053,0.052240662,-0.038384143,-0.019311525,-0.010465386,-0.04061393,0.004207391,-0.013332252,-0.037269253,0.0081493305,-0.044967316,-0.013338888,-0.044781502,0.0129539855,0.036419813,0.04215354,0.03320786,-0.05139122,-0.0034508568,0.0049041985,0.011812548,0.0027241858,0.029358827,0.03610127,-0.014838683,-0.021846578,0.01250272,-0.00772461,-0.036658715,0.0005250943,-0.017148104,0.0022148527,-0.011885547,0.0061816787,-0.018700989,0.01528995,0.024819624,0.035172194,0.006888441,-0.012044817,0.057443492,-0.004622157,-0.042233177,0.017015379,0.009151407,-0.04156955,-0.004160937,0.0038291237,0.007996697,-0.02427545,-0.013949425,0.03910086,-0.012184178,0.017493188,0.022523476,-0.033526402,-0.06694662,0.057868212,0.0056939134,0.0067225345,0.012051454,0.020837866,-0.006052272,0.019616794,-0.039313223,-0.0139759695,0.027208678,0.034296207,0.00056117895,-0.006563264,0.05691259,0.070716016,0.009124861,-0.02827048,-0.019046074,-0.04313571,0.03713653,0.034853652,-0.033287495,0.008368327,0.015781034,0.027208678,-0.0018564946,0.0053886455,-0.027102498,0.015754487,-0.035172194,0.010365843,-0.016909197,-0.011434281,-0.011759458,0.017718822,0.025191255,0.0319337,-0.02700959,0.002629619,-0.014944864,0.028031575,-0.008401508,0.025708882,0.03105771,-0.01550231,0.030978076,0.026730867,0.02317383,0.029863182,-0.013763609,0.04671929,-0.02585488,0.041755367,0.063124135,-0.010677747,0.005498144,0.09375712,0.041277554,-0.035490733,0.009456675,0.049426887,0.04178191,-0.017479917,-0.012834532,0.025416886,0.036658715,0.009065135,0.03315477,-0.036180906,-0.020373328,0.020306965,-0.006490265,0.045073498,-0.007850699,-0.044356782,-0.03530492,0.035278372,0.011294919,-0.0034143573,0.01823645,0.065088466,-0.03442893,-0.008447963,-0.022151846,-0.013378706,0.06763679,0.0863776,-0.011487371,0.03737543,0.016378297,-0.006460402,0.018554991,0.07193709,0.0015304881,-0.02500544,0.0025217799,-0.050966498,-0.0029647504,-0.009158043,-0.033552945,0.0072866166,-0.03599509,-0.026465416,0.043427706,0.04902871,0.027606854,0.007744519,0.023479098,-0.04483459,-0.011341373,-0.04276408,0.010618021,0.0021153088,0.03116389,0.022271298,0.006861896,-0.0061617703,-0.01802409,0.018143542,-0.013066801,0.03947249,0.014958137,1.749796e-05,0.015024499,0.03562346,0.023877274,0.03273005,0.028589021,0.0089191375,-0.02438163,0.011527189,0.032066423,-0.035915453,-0.016736655,0.032438055,0.0037328978,-0.03604818,-0.032331873,0.021674035,0.014148513,0.0055910517,0.011255102,-0.020890955,0.023213647,-0.013186255,0.005106604,-0.011421008,0.0065267645,-0.020997135,0.024421448,-0.046613112,-0.00085441885,0.022218209,-0.023426007,0.020638777,-0.020784775,-0.018568264,-0.05423154,-0.034508567,-0.04709092,-0.043374613,0.026916683,-0.019245163,-0.044861138,0.022271298,0.00074575003,0.012476174,-0.007545431,0.03079226,-0.028615566,0.020585688,0.028695202,0.027421039,-0.0073861605,-0.021408584,0.017984273,0.032464597,-0.04446296,-0.013013711,0.02290838,0.040560838,0.049904697,-0.0034674474,-0.012754898,0.020413145,-0.053992637,-0.046958197,-0.077883184,0.054470446,0.005199512,0.0027092544,-0.009078408,0.00676567,0.07087529,0.008912501,0.015263405,-0.041861545,-0.023678185,-0.00090916804,0.036711805,0.018700989,-0.015143952,0.013484886,-0.063283406,0.00046246458,-0.024023272,-0.004287026,0.01216427,-0.033287495,0.033951122,-0.006609718,0.02033351,0.05643478,0.01544922,-0.009297404,0.02779267,0.018488629,-0.010166755,-0.008799684,0.064663745,-0.022988014,-0.043480795,-0.04871017,-0.0056673684,-0.008036515,0.03825142,0.014387418,-0.019298252,0.008069696,0.019430978,0.0005197023,-0.034083847,-0.03734889,0.010505204,-0.0150510445,-0.110958315,-0.006692671,-0.0563286,-0.045126587,-0.023253465,0.05022324,0.022377478,-0.011606824,-0.012144361,0.01566158,0.0009290768,-0.047250193,-0.024288721,-0.0092244055,-0.014666141,0.0069481675,-0.0070609837,-0.015329767,0.0064504477,0.024726715,-0.0030161815,0.013697247,-0.0073264344,0.01933807,-0.011241829,0.0075786123,-0.02805812,0.07214945,-0.02848284,0.013458341,-0.03904777,0.025523067,-0.009516401,0.0023508961,-0.0024371676,-0.020625506,-0.00914477,-0.014148513,0.0024885987,-0.004940698,0.0038092148,-0.021143133,-0.0027922075,-0.02800503,0.03105771,-0.02679723,0.016272116,0.040481202,0.020983864,-0.03780015,-0.006994621,0.019988423,-0.01550231,-0.00964249,-0.006138543,0.033765305,0.037242707,-0.015940303,0.030500265,0.032517686,-0.005299056,0.0051961937,0.030340994,0.0070012575,-0.0020837865,0.0098349415,0.0002113235,0.006596445,0.01150728,-0.011706368,0.018063908,-0.0018714261,-0.0015114088,0.0070742564,0.01347825,-0.024195815,0.0496127,0.015515583,0.022005849,-0.047197104,0.015727943,0.022563294,-0.012018272,-0.0030344313,0.011859002,-0.02059896,-0.011288283,-0.00078639714,0.004897562,-0.012973894,-0.017639186,0.016404841,0.0003050607,-0.012004999,0.0038523506,-0.022510204,-0.026133602,-0.047011286,0.012476174,-0.008428054,0.015635036,0.000946497,-0.03551728,-0.016657019,0.00048693578,0.030022454,-0.02432854,0.014958137,-0.029465007,0.010485295,-0.014931591,0.014732503,-0.004290344,-0.008846139,-0.0034774018,-0.010040666,-0.02711577,0.011248466,-0.028695202,0.0506745,-0.038596503,0.005654096,-0.0052293753,0.010253026,0.01058484,0.027713034,-0.0032384964,-0.018143542,0.0047382917,0.011049378,-0.012170906,-0.044224057,-0.01896644,-0.03620745,0.0095296735,-0.0034143573,-0.0061285887,0.021514764,0.023134012,-0.015236859,0.018780624,-0.025071802,0.01596685,-0.045073498,0.017294101,0.039313223,-0.03089844,0.004466205,0.0042837076,0.01106265,-0.011328101,-0.034959834,0.0027275041,0.0038158512,-0.004393206,-0.04125101,-0.02180676,-0.010425569,-0.013697247,0.028907562,0.0233331,-0.008839502,0.012509355,-0.005474917,-0.0049307435,0.024235632,0.0038423962,-0.0043633427,0.0071472554,-0.02864211,0.030473718,-0.027341403,-0.080431506,-0.00019856943,0.036499444,0.009489856,0.020240601,0.0028436386,-0.018661171,0.043321524,0.0005607642,0.026292874,0.01923189,0.003885532,-0.012356722,-0.046852015,-0.0039917124,-0.0062214965,0.017705549,0.0012691853,-0.027102498,0.010306116,0.030606445,-0.015435947,0.010856926,0.03201333,-0.010664474,-0.03121698,-0.017161377,-0.009377039,-0.0035902183,-0.05213448,0.049718883,0.042073905,-0.029942818,-0.009071771,0.029650822,-0.00038718447,0.0038158512,-0.04656002,0.060681988,-0.006417266,-0.012788079,-0.005066787,0.022496931,-0.016139392,0.0006362517,-0.018249722,0.05701877,0.020877684,0.03525183,0.007220254,-0.06153143,0.004087938,0.011527189,0.002725845,0.029730458,-0.008003333,0.0020506051,0.03987067,-0.0097088525,-0.037242707,0.03201333,-0.0032766548,0.020997135,0.007193709,0.012681899,-0.0029962726,-0.03158861,-0.01106265,-0.026239784,-0.027421039,0.020267148,0.0002250108,-0.006457084,-0.008945682,-0.020081332,0.009231042,0.030871894,-0.009861487,0.025629247,-0.009808397,0.05160358,0.01342516,-0.013126528,-0.024580717,-0.028881015,-0.006085453,-0.04151646,0.014161785,-0.017307373,0.00068146124,-0.032517686,-0.02001497,-0.0012077999,0.02832357,0.0042837076,0.0028452978,0.012316904,-0.0071538915,-0.066044085,0.0006188315,0.0052227387,-0.029571187,-0.0063276766,0.013199527,0.052240662,0.008122786,-0.0039917124,-0.011195376,0.041012105,-0.018674444,-0.02685032,-0.01939116,0.017745366,0.029093377,0.011255102,-0.036499444,-0.006642899,-0.00041601073,-0.02075823,0.008494416,-0.001086688,0.02532398,-0.038437236,0.005172967,-0.04066702,0.011069287,0.04292335,-0.036340177,0.0049075163,0.034641292,0.0035039468,-0.00454584,-0.019046074,-0.0063674944,-0.021023681,-0.013445069,0.031349707,0.02489926,-0.008520962,-0.026133602,-0.03546419,0.06121289,0.011540461,-0.02175367,0.0009307359,-0.017161377,-0.019696428,-0.025416886,0.02523107,-0.025868153,-0.0073861605,-0.013936152,-0.016338479,0.023797639,-0.0040315297,-0.024447992,-0.009463311,-0.0012102885,-0.019576976,0.014745777,-0.0027075952,-0.02354546,-0.030022454,-0.0017320646,-0.040401567,0.019192072,-0.009177951,0.0024404856,0.012436356,0.038437236,0.034933288,0.00646372,0.0101932995,-0.048524354,-0.019470796,0.019351343,0.0077644275,0.034986377,0.058558382,-0.013544613,-0.00919786,-0.003185406,0.00024803032,0.042737532,-0.02075823,-0.013790154,-0.021103317,0.01619248,0.0073065255,-0.0042107087,0.005683959,0.0012227314,-0.049533065,-0.004068029,-0.00048112907,-0.010883471,0.023518916,-0.008540871,0.015688125,0.001425967,-0.028668655,0.011912092,-0.0041642548,-0.0130070755,-0.024567446,0.0020589007,0.023757821,-0.044728413,-0.023664914,0.0017038605,0.011865638,0.007571976,-0.04119792,0.038596503,0.010684383,0.00013085881,-0.0388885,0.012914168,-0.014772321,0.0025400296,0.02296147,0.011832457,-0.08855429,-0.027739579,-0.034136936,0.008282056,-0.018355902,-0.005272511,-0.0024670307,0.04592294,-0.0078108814,0.024965622,-0.013524704,-0.010405661,0.019165527,0.0074127056,-0.023399463,0.0061750426,0.0070742564,-0.0012907531,0.020293692,-0.016205754,-0.007571976,0.009542946,-0.059673276,0.02296147,-0.009947758,0.04387897,-0.014467053,0.0018598126,-0.015741216,-0.024009999,-0.038304508,0.04592294,-0.008713413,0.014971409,0.03336713,0.009456675,-0.028297026,0.046214934,0.025151437,-0.0059660003,0.024580717,-0.02054587,-0.037508156,0.025164708,0.010458751,-0.030181725,-0.018953167,0.014015787,0.0076383385,0.028403206,0.013962697,0.0015404426,-0.0015885554,0.0022812153,0.031429343,-0.007910426,-0.028297026,0.035119105,0.009635854,0.024076361,0.018674444,0.0069614397,0.013763609,-0.0073264344,0.034136936,0.01681629,-0.029783549,0.021421857,-0.0029630915,-0.011474099,0.008255511,-0.0007544601,0.021581126,-0.026093787,0.0030194996,-0.012834532,0.03984412,0.008627142,0.04528586,0.059885636,0.0033878123,-0.0065699,0.022775654,0.0045226132,-0.019046074,0.007817518,-0.014015787,-0.02800503,-0.015382857,-0.059036195,-0.03384494,-0.0025317343,-0.02438163,-0.00060141133,0.00066652964,-0.0035802638,0.02054587,-0.02065205,-0.047728002,0.018807169,-0.010126937,0.0017967682,-0.0020091287,0.017068468,0.01408215,0.03841069,-0.014652869,0.014334328,-0.009722125,0.012867713,0.018661171,-0.020691868,0.0053023743,0.00015242667,0.034243118,-0.033606034,-0.009980939,-0.0007104949,-0.003082544,0.020718412,0.0011887206,0.0055180527,0.011779367,-0.0066229906,0.0030709307,0.0093504945,-0.021448402,0.018528447,0.023001287,-0.025669064,-0.03379185,-0.0060456353,-0.021780215,-0.014267965,0.03063299,0.029783549,-0.030128634,0.013630884,0.035809275,0.0068751685,0.037959423,-0.01402906,-0.009284132,-0.014214875,0.0068287146,0.014360873,0.04403824,0.024341812,0.0037959423,-0.021727124,-0.013259253,-0.009217769,0.0032235647,0.000699711,0.0035139013,-0.0022513522,-0.04066702,0.006669444,-0.020997135,-0.022032393,0.025987605,0.0269565,0.0005553723,-0.005418509,0.019630065,0.030075543,0.01933807,0.0008535893,0.031854063,0.010538385,-0.010651202,0.006888441,0.005428463,0.027049407,0.010525113,0.018687716,0.074910134,0.016683565,0.014905047,-0.043533884,0.0053820093,0.015475765,0.020293692,-0.030022454,-0.022364207,-0.005023651,-0.0014467053,-0.013292435,0.0070875287,0.01733392,0.03278314,0.012356722,-0.004233936,0.011779367,-0.039233588,-0.023771094,0.0074857045,-0.012210724,0.002672755,-0.027261768,0.029438462,0.029995909,0.0104985675,0.0041012103,0.05086032,-0.012044817,-0.015900485,0.016829563,-0.015887214,0.03509256,0.022417296,0.024341812,0.012914168,-0.010219845,-0.01576776,0.011746185,0.038543414,-0.024607264,0.005783503,-0.010764019,0.012290359,0.032039877,0.028934106,0.020519326,0.028456295,0.0035669913,0.07496323,0.031031165,0.02290838,0.002321033,0.017957726,0.023426007,0.0031970197,0.0026843683,-0.0041178013,-0.021050226,-0.019722974,-0.0038988045,-0.017931182,0.012310267,0.0057934574,-0.0071339826,-0.057602763,-0.014546689,0.01418833,-0.033924576,-0.0012476174,-0.031031165,-0.026518507,-0.0037328978,-7.28952e-05,0.0067026257,-0.005252602,-0.013305707,0.01775864,0.0028718428,0.015635036,0.0033629262,0.010983015,0.0058465474,0.026545051,-0.0036267177,-0.05123195,0.000375571,-0.002546666,-0.018010817,0.019112438,0.021421857,-0.005551234,0.027367948,-0.034136936,0.0005823321,0.001323105,-0.017679004,0.022204936,-0.0228022,0.0040978924,0.014825411,-0.005783503,0.0038921682,0.013644157,-0.0069614397,0.0043036165,0.0221253,0.03100462,0.0024139406,-0.025576157,0.011832457,-0.0023807592,0.024023272,-0.0073728883,-0.0058233207,-0.011872275,-0.008925773,-0.028668655,-0.005026969,0.013936152,-0.0015056022,0.011945273,-0.001564499,0.024660353,-0.035172194,0.015475765,-0.0038589868,0.013644157,0.013385342,-0.006739125,0.008905865,-0.007890517,0.007857336,-0.030261358,-0.010770654,0.010279572,0.0018797214,-0.041330647,-0.017771913,-0.002853593,0.0005586904,0.0021103316,0.0062878593,0.01702865,0.021036953,-0.024116179,0.03315477,-0.022881834,-0.027235223,0.02438163,0.00077436893,-0.03052681,-0.006841987,-0.047117468,0.0028917515,-0.03196024,0.005886365,-0.026306147,0.0079701515,-0.03214606,-0.020824593,-0.0055943695,-0.0044097966,-0.019218618,0.034136936,-0.0052393298,0.037189618,-0.03466784,-0.032491144,0.0046586567,-0.0065068556,-0.018156815,0.0011995045,0.0015221928,0.015542128,0.03657908,0.00057901395,0.010312753,0.0020887638,0.03400421,-0.022483658,0.0052161026,0.012628809,0.018727534,0.023970181,-0.0031688155,-0.0019095846,0.00033886416,-0.03482711,0.027713034,0.017426826,0.017187921,-0.010803836,0.021607673,0.0040978924,0.023810912,-0.012223996,0.0028735017,-0.0034906743,-0.019417705,0.014971409,-0.021474946,0.019935334,0.0072401627,-0.0036798078,-0.02874829,-0.01939116,0.0018946531,-0.006768988,-0.0053654187,-0.0077179736,0.014958137,-0.012569082,0.017174648,0.020784775,-0.021713853,0.016431388,0.024952348,-0.018661171,-0.0054616444,0.0044595688,0.008215694,0.00020800537,-0.009098317,-0.009715489,-0.018754078,0.025934516,-0.022204936,0.033128224,-0.026545051,-0.017625915,-0.031270072,-0.02116968,0.024368357,0.02637251,0.008056424,-0.009669035,0.024009999,-0.00011623829,0.016882652,-0.033977665,0.020744957,0.053249374,0.014214875,0.027766123,-0.0063874032,-0.013551249,-0.021129861,-0.010770654,0.020585688,0.019417705,0.01271508,0.023771094,-0.0150510445,0.010326025,0.03426966,0.0014715913,-0.027235223,-0.014812139,0.03910086,0.03079226,-0.018754078,0.026823774,0.0051099225,-0.0072401627,-0.01944425,0.010438842,-0.021143133,0.024368357,0.020718412,-0.013591066,0.010133574,-0.022788927,-0.014971409,-0.0041775275,0.042233177,-0.013166346,-0.026425598,0.018740807,-0.037269253,0.009151407,-0.010272935,0.025284162,0.0074060694,0.020771503,0.0047648367,0.034083847,-0.019749518,-0.010034029,-0.005113241,-0.017095013,-0.011732913,0.037242707,-0.023930363,-0.0069282586,-0.035066012,-0.0052891015,-0.031986788,-0.039764486,0.017838275,0.0074657956,-0.01981588,-0.010020757,-0.012728352,-0.013199527,-0.0031538839,-0.02553634,0.013604339,0.0038556687,-0.034083847,-0.006158452,-0.008733322,-0.041330647,0.0013164687,-0.0017718822,0.013843245,0.0124164475,-0.017387008,0.014798867,-0.019616794,-0.002345919,-0.03445548,-0.0017204512,0.0070278025,0.022284571,-0.017851546,0.01276817,-0.024315268,-0.044224057,0.013484886,0.03201333,-0.04215354,-0.028721746,-0.015635036,0.005574461,-0.0064239027,0.017479917,-0.0037793517,-0.01227045,-0.020081332,-0.0021368766,-0.03389803,-0.020147694,0.015807578,0.012595627,0.045471672,0.00022625508,-0.0109631065,0.024952348,-0.05165667,0.01539613,0.0054915077,0.0011124036,-0.0070808926,-0.004638748,0.023797639,0.009954395,-0.006735807,-0.008189148,0.00047241896,-0.012628809,0.026399054,-0.020107877,0.0095296735,-0.0015213633,0.0066196723,0.0029166376,-0.04215354,0.013750337,-0.0052227387,-0.0023525553,0.003457493,0.015250132,0.0040846197,-0.021766942,-0.013060166,0.0075852484,0.013026984,-0.0051032864,0.0146395955,-0.00044836252,0.04732983,0.005952728,0.023704732,-0.020744957,-0.001274992,-0.01598012,-0.00072335266,-0.040268842,-0.01639157,0.02489926,0.020904228,-0.01116883,0.023625096,-0.0041045286,0.014745777,0.020705141,0.035596915,0.033659127,-0.027872304,0.030287905,0.023107467,0.021501493,0.0012899236,0.0022248072,0.023917092,-0.011434281,0.039180495,-0.017825002,0.02837666,0.016962288,-0.035172194,0.008129422,0.0049606063,0.030818805,-0.012834532,0.003961849,0.0053986,0.037481613,-0.0136707015,0.024952348,0.0042571626,0.0016001689,0.039791033,0.0197097,-0.049267616,-0.01063793,0.040109575,-0.043109164,0.0319337,-0.008414782,0.009390312,-0.012389903,-0.0075255223,-0.0146926865,-0.0011323123,-0.024739988,-0.020585688]	2025-08-06 10:23:30.428393-04	0
ads	ad2cd4f6-4450-47eb-835a-f726e1c2a1f3	[-0.033038568,-0.003986678,0.029383859,0.00080327457,-0.008497198,-0.0971178,-0.016677655,0.018748656,-0.0120727215,0.009027131,0.03835008,-0.03140613,-0.014314276,-0.014070629,0.06588222,0.0020725245,-0.010635203,-0.030114802,-0.021830793,-0.011963081,0.014484829,0.024547461,0.01087885,0.013912259,0.022269359,-0.0010339781,-0.047608674,-0.004568386,0.02974933,-0.028969659,0.019211587,-0.03145486,-0.05837788,0.019991258,0.0001881604,-0.012669657,-0.027873246,0.016105084,-0.019309046,0.028677281,-0.0020725245,0.068221234,0.04541585,0.0041846414,-0.039690137,-0.005810987,0.03703438,-0.015045218,0.05867026,0.068903446,-0.005366331,0.007869806,-0.04171241,0.012225001,-0.027093574,0.042784456,0.027775787,0.010013903,0.014155906,0.075287,-0.02062474,0.021331318,0.004376514,0.009697161,0.007881989,0.0016994396,-0.02531495,-0.0070292233,0.032307625,0.009550973,-0.009812893,-0.01593453,0.01083012,-0.009715434,-0.004221189,-0.01093367,-0.0066942084,0.030066071,-0.019199403,-0.03727803,0.03520703,-0.031113755,-0.011658521,0.020137446,-0.04336921,-0.037107475,0.012547834,0.0033866968,-0.05949866,-0.0026161624,-0.016251272,-0.010994582,0.037789688,-0.024949478,0.034354262,0.044831093,0.023987072,0.035304487,0.02536368,0.05506428,0.041322574,0.01995471,-0.0004320932,0.028458,0.017030943,0.02062474,0.009325598,-0.012279822,0.013412781,0.012200636,-0.08274261,0.0027242808,-0.02619208,-0.0025811382,-0.001866947,-0.041371305,0.03917848,0.010007811,-0.025095668,-0.055259198,0.00035195609,0.034013156,0.018212633,-0.012231092,-0.019942528,0.00019425158,0.0130473105,-0.036985654,-0.017335502,-0.014813753,0.005223188,0.031942155,0.055551574,-0.018151721,-0.03644963,-0.0048607625,-0.005119638,0.021879524,-0.021148581,-0.01824918,0.03347713,-0.040128704,-0.033842605,0.025582962,-0.066077136,-0.027215399,-0.06495636,-0.03026099,0.0029770648,-0.008643386,0.020978028,-0.006139911,-0.04573259,0.0026374815,-0.004011043,0.039300304,-0.004209006,0.022147536,0.0050313156,-0.060619436,0.060424518,0.013388417,0.018955756,-0.004845535,-0.050191335,0.045610767,0.01619036,-0.00788808,-0.03016353,0.00039097772,-0.016884755,-0.023073396,-0.034256805,0.0078088944,-0.008594657,0.010032176,-0.008131728,0.022476459,-0.00054478005,0.027556505,0.030334083,0.008917489,-0.032916743,-0.0330873,-0.049484756,-0.032746192,0.016409643,-0.048071604,-0.0079611745,0.00029332846,-0.028726012,-0.062763534,0.006191686,0.07553065,-0.0063652843,0.049314205,0.0105682,0.06052198,-0.0046323435,0.047413755,-0.03418371,-0.025095668,-0.0023116034,0.00039554609,0.004933857,-0.00038545756,0.033282217,0.030017342,-0.04244335,0.030309718,0.08069597,-0.009593611,0.02356069,0.040981468,-0.02577788,-0.044319436,-0.007193685,-0.0011550402,0.0069073997,0.0038587635,-0.03294111,-0.024998209,0.03372078,-0.005999814,-0.002649664,0.022269359,0.074263684,-0.02974933,-0.011213865,-0.02784888,-0.020636922,0.02572915,-0.024657102,-0.024364725,-0.0046963007,-0.009983446,0.044124518,0.010355009,0.042930648,-0.04314993,-0.028945293,-0.027800152,-0.021099852,-0.030553365,0.012511287,-0.009057587,-0.031259943,-0.007620068,0.008156092,0.043296117,0.033623323,-0.008491107,0.044173248,-0.02526622,0.053651124,-0.0594012,0.048680723,0.008022086,0.035548136,-0.0066028405,0.0016126402,-0.013546787,-0.0007842396,0.024255084,0.028482364,-0.04254081,-0.01907758,-0.017104037,-0.04970404,-0.0003112213,-0.05043498,0.009161137,0.0455864,-0.012560016,-0.06456652,0.047925416,0.009569246,-0.037302393,0.0031141164,-0.0067002997,-0.002410585,-0.012815845,0.0439296,-0.026898656,0.0076383413,-0.0022522144,-0.0059663123,-0.0047298023,0.00799163,0.017006578,-0.020953665,-0.034768462,-0.0061795036,0.016007625,-0.025948433,0.010239276,0.02923767,-0.031747237,0.020990212,0.0728018,0.030699555,-0.007151047,-0.03264873,-0.059352472,-0.023024665,0.034451723,0.033379674,-0.00033425356,0.07012168,-0.008168275,0.017920256,0.038861737,0.04914365,-0.05418715,0.010245367,-0.052773997,-0.0056739356,-0.052871455,-0.022866296,0.00077129586,-0.019771975,-0.005232325,0.021879524,-0.014119359,-0.03662018,0.0008504812,0.016226906,0.008015995,-0.03579178,-0.041273843,0.078746796,-0.021891706,-0.049070556,-0.03247818,-0.008990584,0.04734066,-0.030943202,-0.026923021,-0.042881917,0.028189987,0.013205681,-0.04232153,0.007833259,-0.0051013646,0.03861809,-0.016105084,-0.013851346,0.03247818,0.055356655,0.023682512,-0.031211214,-0.008966219,0.024766743,0.053846043,-0.030626459,0.0040140883,0.026118986,-0.023183037,0.03228326,-0.013875711,-0.030334083,-0.0113966,0.040396716,-0.013485876,-0.026265174,-0.0071145,-0.04919238,-0.03026099,0.00819873,0.007687071,0.051214654,-0.0054333336,0.019552693,0.017201496,0.0075287004,-0.029310765,0.01438737,0.027166668,0.003095843,0.024998209,0.03835008,-0.003950131,-0.031479225,-0.035353217,0.04397833,0.029091483,-0.03705875,-0.055405386,-0.06203259,0.0055247014,0.040664725,-0.014582288,0.015788343,-0.046219885,0.025144396,0.008606839,0.060034685,0.061837673,-0.008156092,0.013985353,0.012157998,-0.014923395,-0.041980423,-0.003526794,-0.015508148,-0.027361587,0.0045805685,-0.003609025,0.025802244,0.028116893,0.020661287,-8.399168e-05,0.007151047,0.04702392,0.022452094,-0.024827655,-0.009617975,0.044952918,-0.00207557,-0.013668611,0.008497198,-0.033282217,0.041273843,0.0015760931,-0.039275937,0.011640248,0.07679761,-0.021367865,-0.0006616546,-0.03644963,0.016580196,0.0041724592,0.014947759,-0.05413842,-0.014935576,-0.019187221,-0.021367865,0.013485876,0.05589268,0.0021380046,-0.004766349,0.020502916,-0.054528255,0.0046536624,-0.00020900366,0.00086875475,-0.018833933,-0.00066888786,-0.047730498,-0.0014116312,-0.014679747,-0.021124218,0.019979075,0.05944993,-0.032551274,-0.01660456,-0.0380577,-0.022269359,0.020795293,0.005920628,-0.008966219,-0.026240809,-0.021745518,0.009617975,-0.00035043329,0.012206728,-0.022829749,0.004784623,0.023475412,-0.005125729,0.042565174,0.00015323127,0.0039927694,0.040908374,-0.03908102,-0.0043186476,0.015167042,0.032307625,-0.05048371,0.0075774295,0.018980121,-0.0105742905,-0.017445143,0.052091785,2.3270217e-05,-0.033452768,-0.03876428,-0.033842605,-0.008436286,0.0017603515,0.0003296852,0.018492827,0.0824015,-0.011122497,0.002737986,-0.043856505,-0.0025293631,-0.025144396,0.0033958335,0.027239762,0.006779485,-0.026484456,-0.01995471,0.06924455,0.044100154,0.031186849,0.032210167,-0.0025293631,-0.027507775,0.015873618,-0.010221003,0.04858326,-0.010836212,0.003222235,-0.0032465996,0.0028628553,-0.007285053,0.05764694,-0.010757026,-0.031333037,0.021794247,0.026021527,0.003140004,-0.029992977,0.020990212,0.013607699,-0.06861107,-0.055502843,-0.0493873,-0.010616929,0.008210912,0.0016933484,0.0045044287,0.03464664,-0.02041764,0.0011329597,-0.011579336,-0.013900076,-0.060180873,0.021842977,-0.00502827,0.048948735,-0.010281914,-0.0022278496,-0.04064036,-0.014509194,0.010409829,0.027629599,0.02563169,0.03140613,0.015008671,0.0018121265,0.023597237,-0.022439912,0.014107176,-0.045805685,-0.026070256,-0.013997535,-0.0059632664,0.0209293,0.024218537,0.0007827168,-0.0018684699,-0.015130495,0.027653964,0.026435727,0.0155203305,-0.0059845857,-0.0045653405,-0.013205681,-0.031674143,-0.027751422,-0.013461511,0.021879524,0.045147836,0.02794634,-0.008716481,-0.0041024107,-0.019114127,0.03191779,-0.014460465,0.028531093,-0.016616743,0.034573544,0.004233371,-0.02568042,-0.03325785,0.01351024,0.047511216,0.014996489,-0.0057774857,-0.022817565,0.048851274,-0.03608416,-0.036230348,-0.031942155,-0.024937296,-0.0024379953,-0.02376779,-0.00047054378,-0.02083184,0.003712575,0.008284006,-0.040201798,0.0032161437,0.058767717,-0.023158671,0.0015684792,0.023755608,0.0044892007,-0.007790621,0.00038012778,0.008271825,0.0015197498,0.006639388,-0.006852579,0.018529374,0.02041764,0.031113755,-0.0034415175,0.034159344,0.006310464,0.007814986,0.018955756,0.0060759536,-0.0067612114,0.015617789,-0.05949866,-0.059937224,-0.013912259,0.034037523,0.044928554,0.024413455,-0.008838304,0.0061490475,-0.02943259,0.04656099,-0.008771301,0.03893483,-0.023719061,-0.018894844,0.013071675,-0.0029846788,-0.028677281,0.011384418,0.016592378,-0.0049216747,-0.011518424,0.009282961,0.015459418,-0.030626459,-0.017664425,0.034573544,-0.013193499,0.013071675,-0.0027029617,-0.025241856,-0.017213678,0.023938343,-0.031698506,-0.021928253,0.02923767,0.0032953292,-0.011524515,-0.0073581473,0.0017664426,0.009118498,9.78396e-05,-0.022866296,0.010422011,-0.037424218,0.030918837,-0.0041237297,0.01753042,0.005689163,0.027507775,0.036473993,0.017189315,0.014399553,-0.012030083,-0.05067863,-0.0042668725,-0.039275937,-0.025607327,0.024535278,0.04461181,0.037570406,-0.0023984027,0.010531653,-0.022123171,0.025582962,0.00018244992,0.011475786,-0.0030318855,0.029505683,0.0019400413,0.006286099,0.0011398123,0.021976983,-0.027361587,-0.008028177,0.009100225,-0.014423917,0.013668611,-0.013071675,-0.030845743,-0.0057835765,0.024681468,0.01000172,0.050288793,0.0035968425,0.002180643,0.029018387,0.021331318,-0.04444126,0.01824918,-0.029456953,0.0079429,0.01114077,-0.027556505,0.027897611,-0.0594012,-0.007589612,0.018919209,0.0343299,0.007650524,0.015666518,0.007467788,0.019564874,-0.016592378,-0.007546974,-0.021185128,-0.006420105,-0.022269359,-0.013376234,0.016896937,-0.05672108,-0.005192732,-0.046853367,-0.008503289,-0.0034872014,0.02918894,0.0130473105,0.019869434,0.005439425,-0.002456269,0.027507775,0.010080905,0.0057348474,-0.011524515,-0.011810801,0.009349964,-0.021416593,0.023962708,0.0025720014,-0.017981168,-0.019418687,0.007327691,-0.015301048,-0.009045404,-0.020247087,0.022744471,-0.019808521,0.029944248,0.04207788,0.01376607,-0.0031339128,-0.008217004,-0.011950898,0.024571825,0.02000344,-0.0025841836,-0.0148259355,-0.004285146,0.018736474,7.085757e-05,-0.025461137,-0.011213865,-0.018992303,-0.010556017,0.03686383,-0.025558596,0.008107362,-0.027824517,-0.023365771,-0.048022874,0.0038283074,-0.033696417,0.030723918,-0.027361587,0.017116219,0.034402993,-0.0024638828,-0.012791481,-0.008119545,-0.0032922835,0.003877037,-0.043393575,0.018626833,-0.01242601,0.006316555,0.022988118,-0.02706921,0.00443438,-0.010221003,-0.00675512,0.0005482063,0.008150001,-0.016726384,0.042102247,-0.008850487,0.026801199,0.00026991547,0.029018387,0.012913304,0.017713156,0.0067733936,0.034305535,-0.008893125,-0.012584381,0.00634092,-0.013900076,-0.02923767,-0.017420778,0.0326731,0.0036425265,0.011165136,0.019162856,-0.033574592,0.017956803,-0.0060607255,0.0092159575,0.018163903,0.0068038497,-0.047267567,-0.01242601,-0.020576011,-0.007796712,-0.005022179,0.03995815,-0.0061246827,-0.022598283,0.04346667,0.016007625,-0.0074007856,0.015508148,0.022025712,0.0031917791,0.012005718,-0.008082998,-0.027215399,0.014728476,-0.0059937225,-0.00830228,0.03413498,0.026923021,-0.002000953,-0.053894773,-0.023402318,-0.0109214885,-0.03747295,0.029091483,0.03532885,-0.0021242995,0.02943259,-0.016044172,0.010884942,-0.006621114,0.025241856,0.0073216,-0.013522423,0.04860763,-0.0074068764,-0.021270406,-0.027873246,-0.005920628,0.006377467,0.0005124206,0.028311811,-0.04816906,-0.0008070815,-0.0031460952,0.0076687974,0.013912259,-0.0109214885,0.003712575,-0.0121762715,0.027751422,-0.018163903,0.005908446,0.019869434,-0.0014055402,-0.032161437,-0.02376779,-0.0026435726,0.02284193,-0.007041406,0.03903229,0.025241856,0.049070556,-0.0077601653,-0.0030486363,0.014886848,-0.026923021,-0.026581915,-0.011006765,-0.004315602,-0.009678887,0.009751981,0.024730196,0.030455906,0.0028445816,0.038228255,0.0040232255,-0.0076383413,-0.0061277286,-0.0297006,0.0048546717,-0.015118312,-0.013900076,-0.04928984,-0.0038526722,0.00933169,0.004193778,0.0036029338,0.020673469,-0.021489687,-0.025948433,0.050093874,0.02304903,0.013108223,-0.014886848,-0.024608374,0.0094596045,0.011920442,0.018346637,0.012340734,0.012584381,-0.027239762,-0.008107362,0.026947387,0.02408453,0.005168367,-0.010556017,0.008259642,0.008631204,0.012645292,0.011487968,0.012486922,-0.010757026,0.025850974,0.0023481504,0.003758259,-0.023828702,-0.021148581,-0.010397647,0.03944649,0.058280423,0.0451722,-0.009161137,0.0009426103,-0.03294111,-0.043174293,-0.02252519,0.051701948,0.018639015,0.010233184,-0.0032709644,0.023536325,-0.011244321,0.005597796,-0.0013225478,0.0068343054,0.009045404,0.025509868,0.0024258129,-0.006785576,-0.063348286,0.017700974,-0.008990584,0.046317343,0.014704112,-0.026435727,-0.033598956,0.011664612,0.009209867,-0.030967565,0.013960987,0.025802244,-0.01031237,0.03413498,-0.020783111,0.017652243,-0.0008535268,0.025241856,-0.04526966,-0.022208447,-0.048485804,-0.016933484,0.04124948,0.02840927,0.0024349499,0.0053023733,-0.018163903,-0.023365771,-0.03861809,-0.013461511,-0.0021562781,-0.04860763,-0.037180573,-0.0033288307,-0.0036516632,0.01335187,-0.018431915,0.02304903,-0.012828028,-0.009416967,-0.010836212,-0.015033036,0.020308,0.058280423,-0.022050077,-0.0005516326,0.024705831,-0.027727058,0.0095997015,0.014143723,-0.014972124,0.05233543,0.023755608,-0.011031129,0.0104707405,-0.02984679,0.024584008,0.0051653218,0.01706749,0.01794462,-0.029262036,0.0044587445,0.00471762,-0.012255457,0.013729523,-0.010939762,0.021903887,0.0025491593,-0.009569246,-0.008570292,-0.01923595,0.017615696,0.013583334,0.023548508,-0.0067612114,0.023658149,0.03016353,0.040299255,0.03593797,-0.03593797,0.010543835,-0.0133640515,0.005372422,-0.03320912,0.0007297997,0.005116592,-0.011554971,-0.00077776774,-0.009014948,-0.008960128,0.020478552,0.011561062,-0.0034262894,-0.004711529,0.0113966,-0.007687071,-0.00011497105,-0.003065387,-0.02836054,-0.036303442,-0.025388043,-0.007967265,0.015946712,0.0032496452,0.029578777,-0.0008299235,-0.014046264,-0.05486936,0.015617789,-0.033136025,0.033842605,0.030066071,-0.015763978,0.019296862,0.0005443993,0.018699927,-0.006852579,-0.020685652,0.019248134,-0.028433634,0.030187896,0.0010514902,-0.025826609,0.020247087,-0.007181503,-0.0063043726,-0.023170853,-0.022854112,-0.007486062,-0.016872572,-0.0076444326,-0.015325412,0.010860576,-0.0010613884,-0.037546042,-4.2614476e-05,-0.03469537,-0.024523096,0.01314477,0.005418106,0.018602468,0.01438737,0.0069926763,-0.0100869965,-0.011213865,0.011353962,0.064907625,0.019613603,0.023426684,0.009776346,0.04166368,-0.00063805125,-0.02933513,0.012828028,-0.012876757,-0.0048333523,-0.011725524,-0.0017161904,-0.01355897,0.020502916,-0.0046993466,0.013400599,-0.0056130234,0.06495636,0.024047984,-0.035085205,0.00644447,0.024169808,0.024352543,-0.021672424,0.06349447,-0.018468462,-0.034159344,0.034208074,-0.012815845,0.037180573,0.013485876,-0.003505475,0.0020512054,0.0047450303,-0.008710389,-0.022695743,0.014423917,-0.044295073,0.0144361,-0.028238717,-0.027191034,-0.013839164,0.017725337,-0.050045148,-0.035304487,0.0070292233,-0.020856205,-0.015081765,0.032746192,-0.018468462,0.017298955,-0.0027836699,0.002485202,0.0024836792,0.024705831,-0.008320554,-0.010915397,0.033014204,0.013534605,0.03954395,-0.046853367,-0.0011177318,0.022257177,0.016202543,0.00654802,-0.017676609,0.013960987,-0.021428777,-0.00017664426,0.007479971,-0.019942528,-0.017554784,-0.031990886,-0.009301234,-0.04166368,-0.01293767,0.004949085,-0.00958752,-0.0013491967,-0.014168088,0.011804709,0.008076906,0.022208447,0.009758073,-0.031259943,0.016385278,-0.002084707,0.02706921,0.03252691,-0.004373468,-0.016275637,-0.013242228,-0.012584381,-0.001897403,-0.022647012,0.010592564,0.04646353,-0.03990942,0.0008900739,-0.0067977584,0.0035663866,0.00471762,-0.011238229,-0.034256805,-0.019162856,-0.013035128,0.013863529,0.034159344,0.026094621,0.016641108,9.122496e-05,0.0060850903,-0.007948992,-0.0015540126,-0.04332048,-0.0012037697,0.03644963,0.03579178,-0.04273573,-0.0036151162,-0.014119359,0.0032496452,-0.015703065,-0.029383859,0.0030471135,-0.005268872,-0.0022781019,0.016531466,-0.010562109,-0.020819658,-0.0041267755,0.005951084,0.005609978,-0.0055551575,-0.048924368,-0.010525562,0.03954395,-0.009416967,-0.02826308,0.04100583,0.012535651,0.019808521,-0.003758259,-0.01876084,0.02438909,0.019394321,-0.044733636,-0.007352056,0.022025712,-0.0147893885,0.013632064,-0.015873618,-0.0069926763,0.037351124,-0.020551646,0.026752468,0.04149313,-0.025071302,-0.027239762,0.0070353146,-0.021306952,-0.017554784,0.0064322874,-0.017384231,-0.035304487,0.008338828,-0.057354562,0.0024456093,-0.0028476273,0.0041724592,-0.002039023,-0.010336734,0.049314205,-0.01263311,-0.012560016,0.021197312,0.037911512,-0.0069987676,0.008941854,0.018846115,-0.0009471787,-0.0051074554,0.022476459,0.007126682,-0.02526622,-0.024413455,-0.019771975,-0.025388043,0.011999628,-0.02628954,0.009843349,0.003831353,0.026655009,0.008259642,-0.022561736,0.01654365,-0.023682512,-0.0026801198,-0.010714388,-0.016056353,-0.015142676,-0.012901122,-0.03238072,-0.006749029,-0.015435054,-0.00246236,0.005527747,0.023816518,0.005156185,-0.0049795406,-0.010123543,-0.013010764,0.016165996,-0.01087885,0.008497198,0.030114802,-0.008326645,0.012828028,0.018919209,0.029018387,0.0053754677,-0.0091794105,0.021477506,0.021306952,-0.019369956,-0.01706749,-0.0326731,-0.023585055,-0.019430868,-0.0038922648,0.013912259,0.029213306,0.019625787,-0.005582568,-0.009203775,0.007053588,-0.007260688,0.02016181,0.0047876686,-0.012151907,0.005871899,0.018699927,0.014972124,-0.030821377,-0.0022293723,-0.030650824,-0.028604187,-0.010135726,0.010653476,-0.013644246,0.01314477,0.018773021,0.0029648826,-0.010976309,0.019138493,0.0067673023,-0.008290098,-0.0410302,0.0058353515,0.0032161437,-0.035133936,0.024474367,-0.0084484685,0.003027317,-0.022379,-0.027483411,0.022379,0.0015654336,-0.0011245843,-0.02103894,0.034865923,-0.011110315,-0.039422125,0.004339967,0.029627506,0.039690137,-0.016324366,0.004443517,-0.02568042,-0.02587534,0.009630158,-0.021842977,0.0011040266,-0.0035085205,0.01438737,0.0030029523,-0.039714504,-0.034354262,-0.019674515,0.026581915,-0.0007880466,0.033745144,-0.025802244,0.0027516913,-0.0018014669,0.0016476646,0.024937296,-0.00634092,-0.023755608,-0.023390137,-0.038374443,-0.005052635,0.00044465624,-0.0053084646,-0.04346667,-0.02799507,-0.010336734,-0.058962636,-0.041688044,-0.0035816147,0.0071388646,-0.035718687,0.0041755047,-0.023243949,0.03939776,-0.003362332,0.012474739,0.034305535,-0.005637388,-0.00083296903,-0.042760093,0.042297162,0.01912631,0.030723918,0.012547834,-0.0010667181,-0.0117925275,-0.009654523,0.009831167,0.036303442,0.0046597538,0.031893425,0.002737986,0.042102247,0.0033136026,-0.021696787,0.046414804,-0.021282587,0.04244335,-0.005497291,0.018773021,0.0076687974,0.026021527,-0.0078028035,-0.004726757,0.012608745,0.010891032,-0.024827655,-0.010123543,0.021623693,0.0073094177,0.022805383,0.024425637,0.020649105,0.021026758,0.02356069,0.0077114357,-0.050142605,0.026338268,0.008594657,0.01753042,-0.0037917604,-0.005987631,0.0057622576,-0.019357774,-0.0073216,0.011822983,-0.03269746,-0.03294111,0.028336177,-0.0014154383,0.013960987,-0.017213678,0.008399739,0.023865249,0.0016735521,0.059303742,0.0011481877,-0.032746192,-0.0017953757,0.018236997,-0.023950525,-0.018285727,0.028433634,-0.06602841,-0.009081951,0.013473693,0.022232812,-0.0106108375,-0.0031308671,-0.029530047,-0.029895518,-0.036157254,-0.010221003,0.023012483,-0.0114453295,0.008716481,-0.03479283,0.002441041,0.015763978,0.0052871453,0.058718987,-0.019089762,-0.012706204,0.027556505,-0.0012418396,0.033940062,0.0073398734,0.0044374256,0.015849253,-0.005893218,-0.0065236553,-0.011092042]	2025-08-06 17:10:55.894603-04	0
ads	883bd6ac-20e8-4c6e-9680-432432b05209	[0.017018242,0.013774855,-0.016471319,0.040548697,0.0065694484,0.0036217822,-0.04673021,0.036300495,-0.013215212,0.022347571,0.012191319,0.010111736,0.017119996,-0.03256106,0.029762845,0.056218706,-0.028592682,0.026837436,-0.0057617817,0.045153033,0.074076414,0.0048523615,0.022423888,0.03210317,0.043296035,0.017425256,0.023123441,-0.002694873,-0.024115536,-0.0065885275,-0.01371126,-0.041515354,-0.00064470264,-0.012859075,-0.005876254,0.020452417,-0.0045884387,0.046170566,0.04334691,-0.04049782,-0.04001449,-0.002190876,-0.0036122426,0.011027516,-0.01812481,0.074076414,-0.007949478,-0.045610923,0.05998358,0.03762329,-0.001309279,-0.021851525,0.0052911723,-3.716381e-05,-0.047544237,0.028694436,0.02239845,-0.0043881116,-0.023784839,0.009119641,-0.03365491,-0.020986622,0.0121150045,0.016725702,0.0047728666,0.014118273,-0.035969798,0.016369564,-0.024179133,0.003669479,-0.005501039,-0.08735523,0.033349648,-0.014423532,-0.025819905,2.5711592e-05,0.024586145,0.037241712,-0.010270725,-0.010410637,-0.012223117,-0.0010016342,-0.055659063,0.029457586,-0.028796189,0.018366473,0.020617766,-0.00821658,-0.010493311,-0.030856693,-0.007262643,0.0075297453,0.06507125,0.015784483,-0.005106745,-0.0022481123,0.0055073984,0.005895333,-0.009501216,0.08659207,0.043499544,-0.035740852,0.00807667,-0.0051226434,0.010016342,0.028261984,-0.02545105,0.04278727,0.022754585,0.011409091,-0.089492045,-0.018989712,0.005752242,0.0140546765,0.0035391075,0.020528732,0.07204135,-0.024280885,-0.010696817,-0.0213046,-0.014563443,0.008776223,-0.0130880205,-0.013469595,-0.037546974,0.022665551,-0.06817472,-0.017616043,0.010035421,0.027905848,0.015784483,0.020935744,0.022334853,-0.016840175,-0.04540742,-0.014741512,-0.028236546,-0.012051408,-0.02788041,0.054997668,-0.0005727599,-0.04416094,0.01780683,0.024446234,-0.060034458,-0.0039397613,-0.012204039,0.026125165,-0.038462754,-0.009195956,0.017094558,0.00040681454,-0.0099781845,-0.012458421,0.006165615,0.053522244,0.06649579,0.013571349,-0.018620856,-0.023415983,-0.017030962,0.005602792,-0.02208047,-0.031212829,-0.0417443,0.009164158,-0.0076251393,-0.002236983,-0.020223472,-0.0033101626,-0.0073135197,-0.019447602,-0.0034214554,0.00057156745,-0.077179894,0.01126282,0.016992804,-0.014983176,0.002295809,0.038615383,0.016802017,-0.029610215,0.021826087,-0.07417817,-0.01780683,-0.01826472,-0.022474764,-0.016038867,-0.0008800072,0.03149265,-0.008496402,0.034163676,-0.049502987,-0.005539196,-0.006489954,0.052453835,0.01661123,0.031899665,-0.052809972,-0.019562075,0.04520391,0.015046772,0.006836551,0.022449326,-0.047289856,-0.013316966,-0.007644218,0.014283622,0.06792034,0.011981453,0.04266008,0.026430424,-0.026913753,0.01780683,-0.039098714,-0.07514483,-0.0191805,0.03627506,0.050189823,0.0426092,-0.039531164,-0.03347684,0.027447958,-0.031925105,-0.0014825776,-0.013342404,0.049146853,-0.042507447,0.039989054,-0.06166251,0.026277794,0.04281271,0.0280076,-0.035079457,0.04065045,0.046170566,-0.0039524804,-0.032026857,-0.024535269,0.005819018,-0.039810985,-0.01934585,-0.017705077,-0.06395196,0.0041178297,-0.018328317,-0.012083206,-0.033171583,0.0035963438,0.018735329,0.008413727,0.0040287953,-0.037496097,-0.029457586,0.06970102,-0.08236931,0.03368035,-0.014550724,0.011917857,0.034977704,0.0042831786,-0.04334691,-0.0197783,0.020452417,-0.0056091514,0.00472517,0.0033610393,-0.014932299,-0.04372849,0.023085283,0.0029190483,-0.028643558,-0.014296341,-0.0062705483,-0.027498834,-0.021075657,-0.007129092,0.014932299,0.02620148,-0.013736698,-0.039963614,-0.008362851,0.011777947,0.0024627482,-0.013889328,-0.0128845135,-0.0023323768,-0.001050126,-0.01890068,-0.0058985124,0.024090098,-0.026710246,-0.0041369083,-0.046017937,0.0010858987,-0.02742252,0.02571815,-0.026252355,-0.023886591,0.021813367,0.032993514,0.030729502,-0.013304247,-0.016662106,-0.02742252,-0.021393634,-0.0073771155,0.010283445,-0.0138638895,-0.07168521,-0.025629116,0.06507125,0.05438715,-0.06776771,-0.014169149,0.029635653,0.043168847,0.0029142785,0.008203861,-0.056727473,0.013367842,0.0459925,-0.05392926,0.03383298,-0.03627506,-0.0478495,-0.010467872,-0.010340681,-0.03930222,0.009787397,0.0077078138,-8.168088e-05,-0.028872503,-0.036300495,0.034977704,0.036580317,0.038284685,-0.042507447,-0.0009754009,-0.018252002,0.0067411573,-0.026404986,0.06527475,-0.014932299,0.005303892,-0.009711082,-0.007211766,0.042990778,-0.03090757,0.00792404,-0.022894496,-0.023644928,0.013469595,0.0028395534,-0.021889683,0.02693919,0.0026821538,-0.007898601,-0.009959106,0.036783826,0.004435809,8.669899e-06,0.026532177,-0.014181868,-0.006181514,0.035130333,-0.05270822,-0.014868704,0.0023784838,-0.019193219,0.03075494,-0.016191497,0.0018824363,0.026125165,-0.01675114,-0.006060682,0.0121150045,0.038386438,0.047442485,0.0050749467,0.06654667,0.010893964,-0.022856338,0.007014619,-0.014703354,0.036173303,0.0011033876,0.0101753315,-0.0024277705,0.014270903,0.010143533,-0.034061924,0.011657114,0.009615689,0.015631853,-0.010156253,0.053166106,0.005771321,-0.044033747,-0.021088375,0.016992804,-0.039073274,0.026099727,-0.014372656,0.01659851,0.049579304,0.03543559,0.0031909205,0.0417443,-0.033095267,0.03184879,-0.03276457,0.06695368,0.040116247,-0.011949656,0.0030064925,-0.023683084,0.006728438,0.0471881,0.025107631,0.00080925686,-0.050317015,0.013037143,-0.0011534692,0.005815838,0.016395003,-0.0054279035,0.031925105,-0.016242374,0.017565167,-0.052352082,-0.0061592553,0.0061878734,0.0038316483,-0.0075869816,-0.00081084674,-0.00745979,0.006257829,0.013902047,-0.028338298,-0.07173609,0.02253836,0.017921302,0.0417443,-0.011002078,-0.032204926,0.0073198793,0.020770395,-0.01718359,-0.028363736,-0.015453785,-0.005819018,-0.039989054,0.020477856,-0.038132057,-0.014983176,0.02907601,-0.04245657,0.04431357,0.000479751,0.02724445,0.034011047,0.07229573,0.027040944,0.004473966,0.016954646,0.009488497,0.063239686,0.03014442,0.0140038,0.006315065,0.006715719,-0.01659851,0.041667983,-0.038106617,-0.0065376507,0.026633931,0.013520472,-0.045585487,-0.009259552,-0.0019905493,0.022805462,-0.06196777,-0.020897588,0.01690377,-0.02742252,-0.005542376,0.028287422,-0.07946934,-0.022652833,-0.03624962,0.05100385,0.07341502,-0.0132788075,-0.0028268343,0.006728438,-0.016496757,-0.03670751,0.013469595,-0.0063500428,0.008661751,-0.038742576,-0.010512389,-0.017832268,0.0042577405,0.030729502,0.03029705,-0.019205939,-0.01780683,0.013634944,-0.020935744,-0.022614675,-0.009062405,-0.009189596,-0.018061213,-0.042965338,-0.004858721,0.060695853,-0.019104185,0.0015779714,-0.028745312,0.048434578,-0.038310125,-0.037648726,0.010397917,0.026176041,-0.03289176,-0.012324871,0.00020946874,-0.0560152,0.021787928,-0.006346863,0.008267457,0.048968785,-0.021482669,-0.025209384,-0.0017536548,-0.0037330748,0.026633931,-0.030118981,0.009653846,0.029152324,-0.019358568,0.0074788686,-0.029915474,-0.051767,0.011370934,0.025285698,0.0069828215,-0.012057768,0.025056755,0.009946386,3.8207178e-05,-0.0008768274,0.053064354,-0.01537747,0.023568612,-0.01598799,-0.0052593746,-0.014423532,-0.0010230978,-0.005523297,0.015135806,-0.022589236,0.036020674,0.041795176,-0.026048848,0.011014797,-0.0605941,0.015949832,-0.022118628,-0.03169616,-0.002480237,0.031034762,0.033553157,0.049731933,-0.014932299,-0.013698541,0.019689268,-0.020388821,-0.037368905,-0.043296035,-0.010149893,-0.012076847,-0.009221395,0.00685563,-0.028516367,-0.003136864,0.020605046,0.0070591364,0.003440534,-0.022741867,0.0018538182,0.006213312,0.017730515,0.006563089,0.014181868,0.038895205,0.0092023155,-0.018188406,0.0073898346,-0.01795946,-0.050469644,-0.035232086,0.014627039,-0.015326593,0.0059557487,-0.03060231,-0.045738116,0.008483683,-0.0070464173,0.010060859,-0.008439166,-0.034163676,-0.0019905493,0.013037143,-0.02999179,0.045458294,-0.0056504887,-0.006836551,-0.044059187,0.011587159,0.019078746,-0.0009881201,0.0106523,-0.014995895,0.0222331,-0.042074997,0.011281899,-0.0030064925,0.02861812,0.01934585,0.0024182312,-0.018964274,0.013723979,-0.063188806,0.008159344,-0.022614675,-0.0042863586,-0.02131732,-0.022271257,0.015301155,0.0115808,-0.014983176,-0.001141545,0.02877075,0.025972534,-0.0032688254,-0.020732239,0.029610215,-0.004776046,0.038564507,0.035664536,-0.032662816,-0.0067029996,0.0055360165,-0.0018315597,-0.0053102514,-0.022131346,0.03436718,0.027575148,0.055455558,-0.019116905,-0.001279866,-0.013965643,0.006842911,-0.016649386,0.02938127,0.02406466,0.010779492,-0.036936454,0.038030304,0.01965111,-0.006563089,-0.0067665954,0.0103788385,0.004906418,0.009755599,0.0006383431,-0.0086235935,-0.05240296,0.020185314,-0.038284685,-0.00022954117,-0.007580622,0.0039683795,-0.018544542,0.009990904,-0.004795125,-0.021571703,-0.0045439214,-0.025336577,0.07489044,-0.0018808465,-0.018099371,-0.0074407114,0.027346203,0.008292896,0.03734347,-0.113556705,0.03118739,-0.013005346,-0.0109512005,-0.021838807,-0.0055614547,0.004505764,0.014677916,-0.001476218,-0.00019486158,-0.0072181257,-6.0459506e-06,0.0013124588,-0.033069827,-0.04372849,-0.040752202,0.028821627,-0.015631853,-0.032077733,0.044644266,-0.051945068,-0.02785497,0.019892773,-0.0046679336,-0.006419998,-0.032001417,-0.010595064,-0.025908938,0.014665197,-0.01066502,-0.026150603,-0.042227626,-0.006709359,0.015733607,-0.015746325,-0.024560707,-0.0019380827,-0.002038246,0.013736698,-0.008305615,-0.019371288,0.010258006,0.06074673,0.0044803256,0.0064517963,-0.0062991665,-0.0371654,-0.01339328,-0.0015930753,-0.0030478297,0.025171226,0.0005516938,0.010003623,-0.013940205,0.052352082,0.0035995236,0.009819195,0.0037712322,-0.035689976,-0.007338958,-0.023174318,0.01843007,0.029457586,0.018366473,0.0426092,0.0022735507,-0.0487144,-0.024598865,0.028668998,-0.034697883,0.035868045,0.030958448,0.011936936,0.017972179,0.004826923,0.025972534,0.009711082,-0.03731803,0.024573427,0.0041528074,-0.019829178,-0.0067665954,-0.015593695,0.03149265,-0.0016757499,-0.022334853,-0.015898956,-0.005268914,-0.033425964,0.040904835,-0.024980439,-0.03805574,-0.025743589,-0.006165615,0.00974288,-0.021584423,0.014143711,0.01659851,-0.038259245,0.04657758,0.03408736,-0.0006272138,-0.0029651553,-0.038004864,0.0121086445,0.02877075,0.0032624658,-0.026303232,0.0025994792,-0.008947932,0.025769027,-0.0022179044,-0.00046504446,-0.017107276,0.022716427,-0.03195054,-0.03362947,-0.011784306,-0.0020668642,-0.019307692,-0.0052307565,-0.00213205,-0.019880055,-0.021673456,-0.0051798797,0.006607606,-0.002251292,-0.014041957,0.04324516,0.024344482,-0.03790311,-0.036834702,-0.020032683,-0.006044783,0.01628053,0.008388289,-0.022589236,-0.030653186,0.008655392,-0.002408692,-0.030704064,0.032484747,-0.01887524,0.024802372,-0.016700264,0.03301895,0.012973548,-0.0019714704,0.039963614,-0.0019682907,-0.018684452,-0.020083562,0.034011047,-0.041693423,0.044847775,0.0053674877,0.014029238,-0.012420264,0.015631853,-0.0050622276,-0.03149265,-0.021508107,0.034061924,0.021889683,-0.008814381,0.00395884,0.014232745,0.0117334295,0.019002432,0.04232938,0.026633931,-0.037979424,0.03759785,-0.019600233,-0.012954469,0.006458156,0.001766374,-0.01659851,0.014881423,0.013367842,-0.023619488,-0.0035518268,0.0015310694,-0.025044035,-0.022029594,-0.012979908,0.017425256,0.029152324,0.017158153,0.0009483727,0.0017393457,-0.007701454,0.002006448,-0.02238573,-0.025094911,-0.02770234,0.004591618,-0.0046997312,0.02420457,-0.0021558984,0.027193574,0.030704064,-0.00080925686,0.010258006,0.010874886,-0.059322182,0.016776579,-0.016204216,-0.02907601,-0.009723801,0.014385375,0.019625671,-0.027346203,-0.00053340994,0.0069192257,0.008083029,-0.0048460015,-0.005726804,-0.017272625,-0.0022608314,-0.00487144,0.026990067,0.010556906,-0.009844634,0.00020410285,-0.000821976,-0.03958204,-0.019994527,-0.0037076364,0.032535624,0.03927678,0.040777642,0.014779669,0.01371126,0.01766692,3.6989913e-05,-0.044542514,0.014232745,-0.00563459,0.0015549179,-0.043931995,-0.004127369,0.01278912,0.0008815971,-0.016585791,0.021902401,-0.03655488,-0.013444157,0.020312507,0.025298418,-0.045712676,-0.016878331,-0.0088207405,0.02678656,-0.0099781845,0.028083915,0.014538005,0.040294312,0.010302523,0.0014285211,0.05876254,-0.03777592,0.009170517,-0.0026726145,0.036834702,0.03256106,0.022805462,-0.020274349,0.0077268924,0.037572414,0.0010890785,-0.0044262693,0.029762845,0.005278453,0.0040860316,-0.018519104,-0.04398287,-0.011186506,-0.042863585,0.027193574,0.009062405,0.009005168,0.038310125,0.012070487,-0.0074407114,0.022729147,0.04047238,0.012070487,-0.025858061,0.022729147,-0.0065249316,-0.003593164,0.0015382239,0.025298418,-0.032637376,-0.031238269,0.042965338,-0.043143407,0.010696817,-0.023339666,0.007358037,0.01795946,0.0032195386,-0.0009968645,-0.027804093,0.052809972,0.0016868792,0.047137223,0.0128845135,0.007326239,0.0012019611,0.016674824,0.045305666,-0.026811998,-0.01187334,0.031721596,-0.015466504,-0.006261009,-0.01780683,-0.009545733,0.014194588,0.00023192602,-0.028236546,-0.016776579,0.010009983,0.0069955406,0.017730515,0.026862876,0.0048046643,0.029813722,0.012057768,0.0084328065,0.046806525,-0.058202896,0.0018824363,-0.002497726,0.0043912916,0.017170873,-0.03347684,-0.023975626,0.026837436,-0.020185314,-0.0072244853,-0.007580622,-0.023975626,-0.0064772344,-0.0011510844,0.011300977,0.03228124,-0.0025215745,-0.023670366,0.012712805,0.031721596,0.0044230893,-0.006804753,-0.0070464173,0.023975626,-0.023530455,0.00578722,0.0013458466,0.0002146359,0.011517203,0.0054406226,0.011065673,-0.0037076364,0.017857708,-0.022347571,0.014232745,0.018112091,-0.0050177104,-0.028287422,0.013914766,0.024179133,0.019752862,0.025641836,-0.0053770267,-0.0059589287,0.0019285433,0.015466504,0.028668998,-0.037241712,0.016929207,-0.030195298,-0.05118192,0.021953277,-0.0076378584,0.0004415935,-0.023721242,0.019091466,-0.004200504,-0.036453124,0.019307692,-0.030271612,-0.0074661495,0.030653186,-0.02512035,0.015097649,-0.0032910837,0.007383475,0.038004864,0.000958707,0.010525108,0.028847065,-0.041184656,0.0067538763,0.008846179,0.01584808,0.021851525,0.015695449,0.022347571,0.00083787495,0.01659851,0.019752862,0.03777592,-0.044542514,0.002651946,-0.008464604,0.014550724,0.060797606,0.0013673102,0.037699603,0.010531468,-0.027931286,-0.021215567,-0.0053356895,0.0065376507,0.010327961,-0.0064549763,0.023848433,0.02101206,-0.04001449,-0.018468227,0.01339328,-0.03347684,-0.051817875,0.0037839515,-0.024980439,-0.0024770573,-0.001842689,0.00715453,0.015250279,-0.012401186,0.044262692,0.0148305455,-0.010474232,0.04065045,0.03668207,0.029152324,0.07707814,-0.038310125,-0.011898778,0.002359405,0.019854616,0.03744522,-0.008534559,-0.015250279,0.022792744,-0.007294441,-0.01629325,-0.017119996,-0.04416094,-0.023517735,0.01813753,-0.02877075,0.020477856,0.0037839515,0.02724445,-0.04706091,0.008451885,0.0006840526,-0.01447441,0.029330393,0.030780379,-0.015110368,-0.024039222,0.023492297,0.020439697,0.0101816915,-0.005841276,-0.013698541,0.026506739,0.026252355,-0.025285698,0.01870989,-0.023581332,-0.010327961,0.011593519,0.0020605046,-0.028668998,0.011250101,-0.00792404,0.012089566,-0.017984899,0.011161067,0.029661091,-0.012897233,0.009189596,-0.034061924,0.0054024654,0.018608138,0.01980374,-0.004817384,0.020884868,-0.0090178875,-0.007275362,-0.03393473,-0.027524272,0.030449681,-0.027219012,0.009552092,0.023848433,0.035079457,0.0033324212,0.0066394038,-0.022640113,-0.05189419,0.04128641,-0.00791768,-0.008852539,0.034468938,0.006426358,0.016344126,-0.019155063,0.027397081,-0.017399818,-0.02831286,-0.033120703,0.02391203,-0.016064305,0.015809922,0.010086298,-0.0065376507,-0.031289145,0.00792404,-0.009456699,-0.008000354,0.017692357,-0.0027298508,-0.0016049995,-0.0035391075,0.009068765,-0.039454848,-0.0038793453,0.014957737,-0.0073898346,-0.013342404,-0.025145788,0.0017727335,0.013609506,0.029661091,0.0023721242,0.004753788,0.051538054,0.004706091,0.021800648,0.0020938925,-0.019244095,-0.023377825,-0.0063373237,-0.00380939,-0.002329197,-0.014499848,-0.019676547,-0.012560175,-0.0038634462,0.029737407,-0.012280353,0.0033610393,0.016941927,0.04080308,0.025565522,-0.0026074287,0.036427688,0.00021562958,-0.003593164,0.009806476,-0.0015215301,0.0004888929,-0.009164158,0.025921658,0.0028983797,0.011218303,-0.018328317,0.022004155,-0.004979553,-0.012770041,0.051741563,0.00085695373,-0.033400528,-0.01902787,0.042965338,-0.025807185,-0.0040446944,0.002650356,0.011905138,-0.009914589,0.0060670413,-0.0040892116,0.006369122,0.0025358833,0.012935391,-0.0130880205,0.036198743,-0.00015680345,0.0054597016,-0.022423888,0.043652173,-0.0047728666,-0.027524272,0.012649209,0.0038602664,-0.027473396,0.011440889,0.010925762,-0.020121718,0.02087215,0.017119996,-0.009882791,-0.031797912,0.009189596,-0.03319702,0.012515658,0.038030304,-0.02545105,-0.0132788075,-0.013367842,-0.033985607,-0.018964274,-0.010563266,-0.014792388,-0.014805107,-0.009564811,0.0029015595,0.0103724785,0.024624303,-0.0023562252,0.017590605,0.017768674,0.017590605,0.024306323,0.01736166,0.023873871,-0.001112132,0.02693919,0.020274349,-0.0020827632,0.01263649,0.052555587,-0.0026710245,-0.032052293,-0.04550917,0.013138897,-0.011199225,0.020681363,0.01583536,0.0014666787,0.023250634,0.0146397585,-0.015262998,0.039709233,0.0010843088,0.015453785,0.027982162,-0.011205584,-0.015708169,0.009545733,0.025934376,-0.0017981719,0.0036408608,-0.02391203,0.008458245,-0.011695272,0.044491637,-0.019358568,0.026811998,0.012254915,-0.0019587514,-0.016789297,0.006044783,-0.014181868,0.02069408,-0.007669656,0.037394345,0.008451885,-0.036605757,0.01843007,-0.023263352,-0.016242374,0.06563089,-0.010423356,0.003605883,-0.0067983936,0.007186328,-0.0117334295,0.008063951,-0.0020891228,-0.012916312,-0.03454525,0.008916134,0.01994365,-0.038284685,0.024471672,-0.0035136691,0.0071926876,0.039632916,0.016051585,-0.028134793,-0.0078540845,0.0047124503,-0.006747517,0.003396017,-0.013749417,-0.011326416,0.0077078138,-0.022283977,0.028490929,0.00396202,-0.017527008,-0.011300977,-0.012731884,0.016827455,0.0006836551,-0.041210093,-0.011892419,0.02907601,0.016776579,0.05270822,-0.0009571171,-0.040625013,-0.024573427,-0.016674824,0.0016693904,-0.021571703,-0.005281633,-0.013940205,0.001582741,0.014703354,0.0069065066,0.005211678,0.0075297453,0.009761958,0.038259245,0.03228124,-0.0191805,-0.010868526,-0.034443498,-0.013266088,0.0117334295,0.035079457,-0.030322488,0.009971825,0.00020469906,-0.005389746,-0.0076950947,-0.020579608,0.003243387,-0.01461432,0.013405999,-0.04128641,-0.009215035,-0.007262643,0.014461691,0.02298353,-0.025667274,-0.015110368,-0.007173609,0.010226209,0.011879699,-0.004095571,0.01583536,0.0007846135,0.006772955,-0.04416094,-0.015771763,0.010900324,-0.007065496,0.023072565,0.0010437665,0.021826087,0.0058380966,0.028440053,-0.0068874275,0.011956015,0.0017838628,0.016305968,0.011981453,-0.01750157,-0.0025183945,0.019205939,0.007262643,0.023454139,0.02299625,-0.008744426,0.009316788,0.010932122,0.011351855,-0.009056046,0.018226562,-0.017832268,0.044695143,0.014194588,-0.0010095837,0.010391558,0.04080308,0.0028856604,-0.033782102,0.036478564,-0.008254738,0.0047029112,-0.0009920949,-0.02144451,-0.0028093455,0.00685563,0.03790311,0.02419185,-0.018455507,-0.0011645985,0.015441066,0.021088375,-0.021075657,0.00121786,-0.008916134,-0.029890036,-0.013762136,-0.0046011577,0.0426092,-0.0018315597,-0.00897337,0.040116247,0.006715719,0.008718987,0.024649741,0.042710956,0.016547633,-0.007822286,-0.004000177,-0.0037044566]	2025-08-06 17:10:55.894603-04	0
\.


--
-- Data for Name: impression_type_values; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.impression_type_values (value) FROM stdin;
view
click
contextual
fallback
\.


--
-- Data for Name: mcp_tool_call_queries; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.mcp_tool_call_queries (id, mcp_tool_call_id, query_text, query_order, created_at) FROM stdin;
d12baa82-8bbc-4764-9c7a-922b77370510	10e63466-0be2-43d2-a3b5-9ce3cc8ec595	productivity tools	1	2025-08-12 14:48:01.920242-04
02ad4617-a73b-4262-b95a-04bcb997dbae	10e63466-0be2-43d2-a3b5-9ce3cc8ec595	task management	2	2025-08-12 14:48:01.920242-04
de1e47b0-f0ed-40c3-b2e7-29995f46c0dc	bd941296-4927-4551-a81c-b5ee53e353f6	productivity tools for startups	1	2025-08-12 14:48:08.205902-04
88b158ac-b675-48cb-9984-bffc59b6e080	bd941296-4927-4551-a81c-b5ee53e353f6	task management software	2	2025-08-12 14:48:08.205902-04
1eea1b02-e617-45ee-a478-61f42b4713fa	bd941296-4927-4551-a81c-b5ee53e353f6	workflow automation	3	2025-08-12 14:48:08.205902-04
\.


--
-- Data for Name: mcp_tool_calls; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.mcp_tool_calls (id, conversation_id, user_message, hyperlink_ads_returned, display_ads_queued, processing_time_ms, created_at) FROM stdin;
10e63466-0be2-43d2-a3b5-9ce3cc8ec595	819b4810-d7fe-4d1c-8f81-bf04f90d7b6b	I need help with productivity tools	2	5	150	2025-08-12 14:48:01.920242-04
bd941296-4927-4551-a81c-b5ee53e353f6	819b4810-d7fe-4d1c-8f81-bf04f90d7b6b	I'm looking for productivity tools to help with my startup	0	0	6280	2025-08-12 14:48:08.205902-04
\.


--
-- Data for Name: message_ads; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.message_ads (id, message_id, ad_id, slot, shown_at, placement) FROM stdin;
\.


--
-- Data for Name: notifications; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.notifications (id, user_id, type, payload, created_at, read_at) FROM stdin;
\.


--
-- Data for Name: payment_method_values; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payment_method_values (value) FROM stdin;
stripe
ach
wire
paypal
credit_card
bank_transfer
\.


--
-- Data for Name: payouts; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.payouts (id, creator_id, amount, period_start, period_end, status, created_at, updated_at, currency) FROM stdin;
\.


--
-- Data for Name: preference_status_values; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.preference_status_values (value) FROM stdin;
allowed
blocked
preferred
\.


--
-- Data for Name: session_ad_type_overrides; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.session_ad_type_overrides (id, session_id, ad_type, is_enabled, created_at) FROM stdin;
983aa714-b9ce-45d5-b848-9edd11870102	0839ab22-e816-41e8-a8b0-09615a9af50c	hyperlink	t	2025-08-11 16:27:27.958853-04
f2a6c956-275a-4db0-ad3f-183095e4b24c	0839ab22-e816-41e8-a8b0-09615a9af50c	popup	t	2025-08-11 16:27:27.958853-04
8d6eee97-cb98-44c9-8c9a-3c988be8ec6e	0839ab22-e816-41e8-a8b0-09615a9af50c	banner	t	2025-08-11 16:27:27.958853-04
be16f8c2-7c56-4db1-8c0f-0f03762bf129	0839ab22-e816-41e8-a8b0-09615a9af50c	video	t	2025-08-11 16:27:27.958853-04
6ebc2dee-7b77-40af-9323-3a5aab83b01f	0839ab22-e816-41e8-a8b0-09615a9af50c	thinking	t	2025-08-11 16:27:27.958853-04
a037fc39-0244-4b5e-b74e-8b4956e42c20	c0e3a982-1d63-4b49-bad3-70e94b757cd8	hyperlink	t	2025-08-11 16:32:52.33066-04
e08ea2c9-4898-45ac-aa50-d5c55195efff	c0e3a982-1d63-4b49-bad3-70e94b757cd8	popup	t	2025-08-11 16:32:52.33066-04
abd6157f-1756-4f75-9d37-d737782cc2be	c0e3a982-1d63-4b49-bad3-70e94b757cd8	banner	t	2025-08-11 16:32:52.33066-04
39f34718-cfcf-4bcd-92d0-419631581fa9	c0e3a982-1d63-4b49-bad3-70e94b757cd8	video	t	2025-08-11 16:32:52.33066-04
4e498c4d-962d-43d4-9689-1f9913fe03a9	c0e3a982-1d63-4b49-bad3-70e94b757cd8	thinking	t	2025-08-11 16:32:52.33066-04
f8492c23-c945-4ace-b838-b8613af01306	e32b92d2-b5f5-4a8b-bbf5-411440e60593	hyperlink	t	2025-08-11 16:57:01.937482-04
8a009e5c-e067-4b23-a27e-25607dfc6ca8	e32b92d2-b5f5-4a8b-bbf5-411440e60593	popup	t	2025-08-11 16:57:01.937482-04
040e8243-d10a-48c9-a383-c8ad06485c14	e32b92d2-b5f5-4a8b-bbf5-411440e60593	banner	t	2025-08-11 16:57:01.937482-04
1a8ddc57-d0c7-4556-8aa9-227ba87e1ea4	e32b92d2-b5f5-4a8b-bbf5-411440e60593	thinking	t	2025-08-11 16:57:01.937482-04
a24f0ba1-8019-4dca-81fc-17e4791c29b4	83cd360f-5f4b-4290-aab3-a5b149f9b8fa	hyperlink	t	2025-08-11 16:57:58.751787-04
527f4a84-db6b-45e6-ae97-bbdcad1941fd	83cd360f-5f4b-4290-aab3-a5b149f9b8fa	popup	t	2025-08-11 16:57:58.751787-04
62f3b34e-6a92-4feb-9bb4-97afd5bc5711	83cd360f-5f4b-4290-aab3-a5b149f9b8fa	banner	t	2025-08-11 16:57:58.751787-04
80d2e06b-cc10-4d0c-b939-9bbd06c0ff5a	83cd360f-5f4b-4290-aab3-a5b149f9b8fa	thinking	t	2025-08-11 16:57:58.751787-04
eca36db8-55a5-4f76-be6c-d4a23c73249a	dcf438f4-0e44-4625-95b5-9f24a290e759	hyperlink	t	2025-08-11 17:04:32.581545-04
d9988649-e472-472d-bfd6-6e1717ce80b7	dcf438f4-0e44-4625-95b5-9f24a290e759	popup	t	2025-08-11 17:04:32.581545-04
97b0ec9d-2f41-48fb-9186-fc406b2afc60	dcf438f4-0e44-4625-95b5-9f24a290e759	banner	t	2025-08-11 17:04:32.581545-04
8e3fd17a-4fd3-4e7b-9fd7-4a4a0d938139	dcf438f4-0e44-4625-95b5-9f24a290e759	thinking	t	2025-08-11 17:04:32.581545-04
664aa85b-29c0-4267-9dc5-454add6080d3	570caf35-b9ef-4ea2-b0ad-6211b2de7c88	popup	t	2025-08-11 17:04:57.308722-04
a150e071-1721-4810-ba33-a254576160d3	570caf35-b9ef-4ea2-b0ad-6211b2de7c88	hyperlink	t	2025-08-11 17:04:57.308722-04
f9a0fdcc-76b6-4446-9a75-872f363849c2	fa820f26-eb8a-4cd4-9b98-068f76812cff	hyperlink	t	2025-08-11 17:10:19.567927-04
abbb5c07-e6db-4eec-b31e-2d6d9635771b	fa820f26-eb8a-4cd4-9b98-068f76812cff	popup	t	2025-08-11 17:10:19.567927-04
18b17e27-09e8-445b-9ed9-cee32423aca8	fa820f26-eb8a-4cd4-9b98-068f76812cff	banner	t	2025-08-11 17:10:19.567927-04
72ee75ff-17a9-49b7-ba8c-10b61e2dd837	fa820f26-eb8a-4cd4-9b98-068f76812cff	thinking	t	2025-08-11 17:10:19.567927-04
acb62144-e7a3-4071-bf17-a3dcd0799b38	dcaab217-4bbe-4b2f-9428-c667519912fb	hyperlink	t	2025-08-11 17:11:18.624986-04
4a197296-5e6f-4dd0-9d91-c0fb7fed6727	dcaab217-4bbe-4b2f-9428-c667519912fb	popup	t	2025-08-11 17:11:18.624986-04
1cc9a13c-d786-43f6-9319-22d10357e7ed	dcaab217-4bbe-4b2f-9428-c667519912fb	banner	t	2025-08-11 17:11:18.624986-04
c38109e6-b32d-4f73-bbed-fd47ccf176d3	dcaab217-4bbe-4b2f-9428-c667519912fb	thinking	t	2025-08-11 17:11:18.624986-04
65d61d9b-7064-4d5c-8726-5fe132428a24	fb1c6ef7-9d27-4a76-aedc-8078aac81d71	hyperlink	t	2025-08-11 17:17:42.34826-04
3ee05970-dadd-40a9-baf4-f445161c7ee1	fb1c6ef7-9d27-4a76-aedc-8078aac81d71	popup	t	2025-08-11 17:17:42.34826-04
9a9d8c62-3b86-4e15-b8f3-1ee477fd14a3	fb1c6ef7-9d27-4a76-aedc-8078aac81d71	banner	t	2025-08-11 17:17:42.34826-04
8956a435-e2e0-4c6a-a074-dd911a505b8b	fb1c6ef7-9d27-4a76-aedc-8078aac81d71	thinking	t	2025-08-11 17:17:42.34826-04
0d551601-5e37-49e5-aed4-1d2231624f92	140892d7-e913-4211-9ad4-e26d56657fe6	hyperlink	t	2025-08-11 17:18:25.999827-04
55845077-fd88-47a1-b5e6-989b4d0bc727	140892d7-e913-4211-9ad4-e26d56657fe6	popup	t	2025-08-11 17:18:25.999827-04
0f18817c-9f2b-4a48-b0cb-f74089dfeac1	140892d7-e913-4211-9ad4-e26d56657fe6	banner	t	2025-08-11 17:18:25.999827-04
d83e5fae-bbc8-4da2-b253-ab489829ce2e	140892d7-e913-4211-9ad4-e26d56657fe6	thinking	t	2025-08-11 17:18:25.999827-04
08703102-a62f-4e19-9bf4-b7d4b5c96f91	279b66c1-181d-4672-b139-a4e3e76b168b	hyperlink	t	2025-08-11 17:19:21.326961-04
94f68aa7-3f6f-42b6-b8ad-db53f4153c71	279b66c1-181d-4672-b139-a4e3e76b168b	popup	t	2025-08-11 17:19:21.326961-04
049a90b4-1124-4f33-943c-8cd2fb239349	279b66c1-181d-4672-b139-a4e3e76b168b	banner	t	2025-08-11 17:19:21.326961-04
cf18e54a-1fee-41f2-9851-7a3c77624ddb	279b66c1-181d-4672-b139-a4e3e76b168b	thinking	t	2025-08-11 17:19:21.326961-04
01463566-e7b1-4566-81b5-dcdcf08b56a6	59804079-3212-45d2-8629-68ff773a622f	hyperlink	t	2025-08-11 17:19:51.588745-04
152a1c43-a2df-4ba9-86b6-0315344581c0	59804079-3212-45d2-8629-68ff773a622f	popup	t	2025-08-11 17:19:51.588745-04
4de25f75-4529-4ea7-92c3-bd0a5a336e45	59804079-3212-45d2-8629-68ff773a622f	banner	t	2025-08-11 17:19:51.588745-04
8ed8a8ac-4e08-47b2-83a3-a3b2d53f81e6	59804079-3212-45d2-8629-68ff773a622f	thinking	t	2025-08-11 17:19:51.588745-04
b75a6c9b-0447-46fc-b174-3865ae4ec0ef	a5b0d78b-7a07-49b1-846b-ef23ae317976	hyperlink	t	2025-08-11 17:20:32.379229-04
37ad9f5b-e8d5-465e-a3bd-790f299978c3	a5b0d78b-7a07-49b1-846b-ef23ae317976	popup	t	2025-08-11 17:20:32.379229-04
6273e9ac-26b4-44fb-ae9d-39750faf851b	a5b0d78b-7a07-49b1-846b-ef23ae317976	banner	t	2025-08-11 17:20:32.379229-04
d8d65fdc-0f05-421e-868d-d6c373b3b96d	a5b0d78b-7a07-49b1-846b-ef23ae317976	thinking	t	2025-08-11 17:20:32.379229-04
6da393fa-e843-470f-bb00-4e42bd8a5506	efefefad-77aa-432b-8e77-09eae9f76220	hyperlink	t	2025-08-11 17:20:59.675117-04
e1a942e0-8668-41bb-a6a3-a21c3cf704e6	9a0efa54-7ac0-4ff4-88c4-78944f1608d9	hyperlink	t	2025-08-11 17:21:24.627737-04
c8033d37-d53b-4465-bff9-32d98b00d89e	9a0efa54-7ac0-4ff4-88c4-78944f1608d9	popup	t	2025-08-11 17:21:24.627737-04
50d416fd-19c8-49b5-b85c-1434fa68e338	9a0efa54-7ac0-4ff4-88c4-78944f1608d9	banner	t	2025-08-11 17:21:24.627737-04
85d83a2b-0fa9-46e8-b07a-869e09b1e69b	9a0efa54-7ac0-4ff4-88c4-78944f1608d9	thinking	t	2025-08-11 17:21:24.627737-04
5b6f59ba-c4f3-4283-9620-e61894e2d712	1cbc31b7-a37d-4dfe-a212-fc59ea5c3378	hyperlink	t	2025-08-11 17:22:04.191026-04
6c569917-8050-4452-8838-4de5f0469c4f	1cbc31b7-a37d-4dfe-a212-fc59ea5c3378	popup	t	2025-08-11 17:22:04.191026-04
6b6c7520-8dda-41fa-91ff-985b92a0a015	1cbc31b7-a37d-4dfe-a212-fc59ea5c3378	banner	t	2025-08-11 17:22:04.191026-04
c72bf481-0461-4918-ab69-80e77e7d8845	1cbc31b7-a37d-4dfe-a212-fc59ea5c3378	thinking	t	2025-08-11 17:22:04.191026-04
\.


--
-- Data for Name: user_roles; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.user_roles (id, user_id, created_at, role) FROM stdin;
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.users (id, email, password_hash, created_at, updated_at, deleted_at) FROM stdin;
ab4acdbb-298d-4780-8029-e79f05f1c23d	earnlayer@demo.com	demo	2025-06-21 20:45:45.377357-04	2025-06-21 20:45:45.377357-04	\N
0963ca49-131e-45ec-843e-68970e5cd962	superhuman@demo.com	demo	2025-06-21 20:45:45.392563-04	2025-06-21 20:45:45.392563-04	\N
671b93af-8e85-4224-b0a1-8908e0665e13	adresponsetest_a4cfa188@test.com	test	2025-07-19 08:35:21.935851-04	2025-07-19 08:35:21.935851-04	\N
e8792571-696e-4377-a188-56dcf6136122	techcorp@demo.com	demo	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N
79046a8b-9ada-4ab7-9c02-de11d96cc130	sparkloop@demo.com	demo	2025-06-22 11:39:02.717192-04	2025-06-22 11:39:02.717192-04	\N
58ea31a1-7a0f-4804-bae1-122351c64823	toolhouse@demo.com	demo	2025-06-22 11:39:02.717192-04	2025-06-22 11:39:02.717192-04	\N
043d11c7-e5db-4d4f-94ee-3d8c729432ef	bookstore@demo.com	demo	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N
f3c7c6d1-81fe-4b7e-94de-95d89406ea42	softwarecorp@demo.com	demo	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N
3b8b4fa4-114c-4c9a-aa66-3ae3d4e846fc	testcorp@demo.com	demo	2025-08-06 10:23:30.428393-04	2025-08-06 10:23:30.428393-04	\N
4f543409-619d-4b7d-bfee-74723bebfef8	instantly_ai@demo.com	demo	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	\N
e8b2b263-3e8d-4523-b88f-bc7297570535	default@earnlayer.com	default_password	2025-07-03 21:34:01.280335-04	2025-07-03 21:34:01.280335-04	\N
5375926e-b797-4c36-b9b6-0a28e0f2befb	shopify@demo.com	demo	2025-08-06 17:10:55.894603-04	2025-08-06 17:10:55.894603-04	\N
41bbb10e-1399-4fc5-9825-e9c9101e30ff	test@example.com	hashed_password	2025-07-13 21:45:57.880975-04	2025-07-13 21:45:57.880975-04	\N
45f89fcb-3be9-4f24-985a-ed078d588c76	wondershare@demo.com	demo	2025-07-18 18:28:03.733773-04	2025-07-18 18:28:03.733773-04	\N
a2ba48f4-d3a9-42b6-a1c7-928bd3bf6d75	nordvpn@demo.com	demo	2025-07-18 18:28:03.733773-04	2025-07-18 18:28:03.733773-04	\N
a09539e0-56ff-4683-9bc2-3b44582a2b82	acronis@demo.com	demo	2025-07-18 18:28:03.733773-04	2025-07-18 18:28:03.733773-04	\N
fcbddd8e-b5cb-41ee-bff0-be4eadbb9b78	amazon_affiliate@demo.com	demo	2025-07-18 18:28:03.733773-04	2025-07-18 18:28:03.733773-04	\N
0b9cbe76-6582-4da4-872c-198346d43200	existing@test.com	test	2025-07-18 18:31:20.013578-04	2025-07-18 18:31:20.013578-04	\N
d81659b6-bb32-4d9b-95ac-7c4d52afdbff	existing-b01fa800-6b43-47e4-8377-9420d5f4ba92@test.com	test	2025-07-19 08:14:44.440789-04	2025-07-19 08:14:44.440789-04	\N
84a48840-1666-4a0e-a194-b6a3f10a9926	testadvertiser1@demo.com	demo	2025-07-19 08:23:46.287544-04	2025-07-19 08:23:46.287544-04	\N
0de7f662-36c4-4c0a-9f95-cccea454d8c9	testadvertiser2@demo.com	demo	2025-07-19 08:23:46.287544-04	2025-07-19 08:23:46.287544-04	\N
7cdfbf3f-92fe-4b97-996f-dde113211fb5	test@test.com	test	2025-07-19 08:32:47.867233-04	2025-07-19 08:32:47.867233-04	\N
\.


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

