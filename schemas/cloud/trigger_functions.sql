-- Trigger function definitions for schema public
CREATE OR REPLACE FUNCTION public.enforce_campaign_active_for_ads()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$


CREATE OR REPLACE FUNCTION public.sync_campaign_spent_and_status()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$


CREATE OR REPLACE FUNCTION public.trigger_refresh_effective_cpc_rates()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    PERFORM public.refresh_effective_cpc_rates();
    RETURN COALESCE(NEW, OLD);
END;
$function$


CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$function$


CREATE OR REPLACE FUNCTION public.validate_embeddings_source_fk()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
$function$


