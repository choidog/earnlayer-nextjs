-- Views for schema public
CREATE OR REPLACE VIEW public.v_active_campaigns_ads AS
 SELECT ac.id AS campaign_id,
    ac.name AS campaign_name,
    ac.advertiser_id,
    ac.budget_amount,
    ac.spent_amount,
    ac.start_date,
    ac.end_date,
    ac.status AS campaign_status,
    a.id AS ad_id,
    a.title,
    a.content,
    a.target_url,
    a.ad_type,
    a.placement,
    a.pricing_model,
    a.status AS ad_status
   FROM ad_campaigns ac
     JOIN ads a ON a.campaign_id = ac.id
  WHERE ac.status = 'active'::campaign_status AND a.status = 'active'::ad_status AND ac.end_date > now() AND ac.spent_amount::numeric < ac.budget_amount::numeric;;
CREATE OR REPLACE VIEW public.v_ads_with_embeddings AS
 SELECT a.id,
    a.campaign_id,
    a.title,
    a.description,
    a.url,
    a.created_at,
    a.updated_at,
    a.deleted_at,
    a.ad_type,
    a.pricing_model,
    a.status,
    a.image_url,
    a.needs_description,
    a.estimated_epc,
    a.placement,
    a.bid_amount,
    a.target_url,
    a.content,
    a.embedding,
    e.embedding::text AS embedding_text,
    e.embedding AS embedding_vector
   FROM ads a
     LEFT JOIN embeddings e ON e.source_id = a.id AND e.source_table = 'ads'::text AND e.chunk_id = 0;;
CREATE OR REPLACE VIEW public.v_users AS
 SELECT id,
    email,
    name,
    picture,
    email_verified,
    provider,
    created_at,
    updated_at
   FROM auth_users;;
CREATE OR REPLACE VIEW public.v_users_with_creators AS
 SELECT au.id AS user_id,
    au.email,
    au.name AS user_name,
    au.picture,
    au.email_verified,
    au.provider,
    c.id AS creator_id,
    c.name AS creator_name,
    c.bio,
    c.is_active,
    c.approval_status,
    c.approval_date,
    c.permissions,
    c.user_id AS legacy_user_id
   FROM auth_users au
     LEFT JOIN creators c ON c.auth_user_id = au.id;;
