-- TIPPOS market intelligence foundation.
-- Isolated from payments and user balances by design. All ingestion is
-- service-role only; authenticated reads go through narrow role-checked RPCs.

CREATE SCHEMA IF NOT EXISTS market_intelligence AUTHORIZATION postgres;
REVOKE ALL ON SCHEMA market_intelligence FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA market_intelligence TO service_role;

CREATE TYPE market_intelligence.access_role AS ENUM ('viewer', 'analyst', 'admin');
CREATE TYPE market_intelligence.source_kind AS ENUM (
  'search_console', 'keyword_provider', 'trends', 'analytics', 'internal_search',
  'ai_provider', 'manual_import', 'synthetic'
);
CREATE TYPE market_intelligence.connector_status AS ENUM (
  'enabled', 'mock', 'paused', 'disabled_pending_credentials', 'disabled_policy'
);
CREATE TYPE market_intelligence.job_status AS ENUM (
  'queued', 'running', 'succeeded', 'partially_succeeded', 'failed', 'cancelled'
);
CREATE TYPE market_intelligence.data_nature AS ENUM ('measured', 'third_party', 'inferred', 'synthetic');
CREATE TYPE market_intelligence.search_intent AS ENUM (
  'informational', 'commercial', 'transactional', 'navigational', 'local', 'unknown'
);
CREATE TYPE market_intelligence.language_product_status AS ENUM (
  'not_evaluated', 'researching', 'planned', 'supported', 'paused'
);
CREATE TYPE market_intelligence.language_recommendation AS ENUM (
  'maintain', 'implement', 'validate', 'monitor', 'deprioritize'
);

CREATE OR REPLACE FUNCTION market_intelligence.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION market_intelligence.normalize_text(p_value text)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = ''
AS $$
  SELECT lower(regexp_replace(btrim(p_value), '[[:space:]]+', ' ', 'g'));
$$;

CREATE TABLE market_intelligence.access_roles (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role market_intelligence.access_role NOT NULL,
  granted_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION market_intelligence.has_minimum_role(p_required market_intelligence.access_role)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT coalesce(
    (SELECT CASE ar.role
      WHEN 'admin'::market_intelligence.access_role THEN 3
      WHEN 'analyst'::market_intelligence.access_role THEN 2
      ELSE 1 END
     FROM market_intelligence.access_roles ar
     WHERE ar.user_id = auth.uid()), 0
  ) >= CASE p_required
    WHEN 'admin'::market_intelligence.access_role THEN 3
    WHEN 'analyst'::market_intelligence.access_role THEN 2
    ELSE 1 END;
$$;

CREATE TABLE market_intelligence.languages (
  code text PRIMARY KEY CHECK (code ~ '^[a-z]{2,3}(-[A-Z][a-z]{3})?(-[A-Z]{2}|-[0-9]{3})?$'),
  english_name text NOT NULL,
  native_name text NOT NULL,
  text_direction text NOT NULL DEFAULT 'ltr' CHECK (text_direction IN ('ltr', 'rtl')),
  product_status market_intelligence.language_product_status NOT NULL DEFAULT 'not_evaluated',
  estimated_localization_cost numeric(12,2) CHECK (estimated_localization_cost IS NULL OR estimated_localization_cost >= 0),
  notes text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.sources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_key text NOT NULL UNIQUE CHECK (source_key ~ '^[a-z0-9][a-z0-9_-]{1,63}$'),
  display_name text NOT NULL,
  kind market_intelligence.source_kind NOT NULL,
  status market_intelligence.connector_status NOT NULL DEFAULT 'disabled_pending_credentials',
  base_url text,
  documentation_url text,
  terms_url text,
  collection_method text NOT NULL CHECK (collection_method IN ('official_api', 'first_party', 'manual', 'mock')),
  data_nature market_intelligence.data_nature NOT NULL,
  default_confidence numeric(4,3) NOT NULL DEFAULT 0.800 CHECK (default_confidence BETWEEN 0 AND 1),
  rate_limit_per_minute integer CHECK (rate_limit_per_minute IS NULL OR rate_limit_per_minute > 0),
  retention_days integer NOT NULL DEFAULT 365 CHECK (retention_days BETWEEN 1 AND 3650),
  config_schema jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(config_schema) = 'object'),
  last_success_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.connector_accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES market_intelligence.sources(id) ON DELETE CASCADE,
  account_key text NOT NULL,
  display_name text NOT NULL,
  credential_reference text,
  status market_intelligence.connector_status NOT NULL DEFAULT 'disabled_pending_credentials',
  scopes text[] NOT NULL DEFAULT '{}',
  external_account_id text,
  last_verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id, account_key),
  CHECK (credential_reference IS NULL OR credential_reference !~* '(secret|token|password)\s*[=:]\s*[^ ]+')
);

CREATE TABLE market_intelligence.connector_configs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  connector_account_id uuid NOT NULL REFERENCES market_intelligence.connector_accounts(id) ON DELETE CASCADE,
  config_key text NOT NULL,
  config_value jsonb NOT NULL,
  is_secret_reference boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (connector_account_id, config_key)
);

CREATE TABLE market_intelligence.collection_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES market_intelligence.sources(id) ON DELETE RESTRICT,
  connector_account_id uuid REFERENCES market_intelligence.connector_accounts(id) ON DELETE SET NULL,
  external_key text NOT NULL,
  job_type text NOT NULL,
  status market_intelligence.job_status NOT NULL DEFAULT 'queued',
  cursor_value text,
  dry_run boolean NOT NULL DEFAULT false,
  requested_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  finished_at timestamptz,
  rows_seen integer NOT NULL DEFAULT 0 CHECK (rows_seen >= 0),
  rows_loaded integer NOT NULL DEFAULT 0 CHECK (rows_loaded >= 0),
  rows_rejected integer NOT NULL DEFAULT 0 CHECK (rows_rejected >= 0),
  error_code text,
  error_summary text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id, external_key),
  CHECK (finished_at IS NULL OR started_at IS NULL OR finished_at >= started_at)
);

CREATE TABLE market_intelligence.collection_job_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id uuid NOT NULL REFERENCES market_intelligence.collection_jobs(id) ON DELETE CASCADE,
  attempt_number integer NOT NULL CHECK (attempt_number > 0),
  status market_intelligence.job_status NOT NULL,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  retry_after timestamptz,
  error_code text,
  error_summary text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (job_id, attempt_number)
);

CREATE TABLE market_intelligence.raw_observations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES market_intelligence.sources(id) ON DELETE RESTRICT,
  job_id uuid REFERENCES market_intelligence.collection_jobs(id) ON DELETE SET NULL,
  external_id text,
  observation_type text NOT NULL,
  event_at timestamptz NOT NULL,
  ingested_at timestamptz NOT NULL DEFAULT now(),
  schema_version smallint NOT NULL DEFAULT 1 CHECK (schema_version > 0),
  data_nature market_intelligence.data_nature NOT NULL,
  confidence numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  checksum text NOT NULL CHECK (length(checksum) = 32),
  payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id, observation_type, checksum)
);

CREATE TABLE market_intelligence.topics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id uuid REFERENCES market_intelligence.topics(id) ON DELETE SET NULL,
  slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  name text NOT NULL,
  description text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.keywords (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  original_text text NOT NULL CHECK (length(original_text) BETWEEN 1 AND 500),
  normalized_text text NOT NULL CHECK (length(normalized_text) BETWEEN 1 AND 500),
  language_code text NOT NULL REFERENCES market_intelligence.languages(code) ON DELETE RESTRICT,
  country_code text CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$'),
  intent market_intelligence.search_intent NOT NULL DEFAULT 'unknown',
  funnel_stage text NOT NULL DEFAULT 'unknown' CHECK (funnel_stage IN ('awareness', 'consideration', 'conversion', 'retention', 'unknown')),
  persona text,
  industry text,
  use_case text,
  is_branded boolean NOT NULL DEFAULT false,
  business_relevance numeric(5,2) NOT NULL DEFAULT 50 CHECK (business_relevance BETWEEN 0 AND 100),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX keywords_natural_uniq ON market_intelligence.keywords
  (normalized_text, language_code, coalesce(country_code, '*'));

CREATE TABLE market_intelligence.keyword_variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  keyword_id uuid NOT NULL REFERENCES market_intelligence.keywords(id) ON DELETE CASCADE,
  variant_text text NOT NULL,
  normalized_text text NOT NULL,
  variant_type text NOT NULL CHECK (variant_type IN ('spelling', 'translation', 'question', 'singular_plural', 'related')),
  language_code text NOT NULL REFERENCES market_intelligence.languages(code) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (keyword_id, normalized_text, language_code)
);

CREATE TABLE market_intelligence.keyword_topics (
  keyword_id uuid NOT NULL REFERENCES market_intelligence.keywords(id) ON DELETE CASCADE,
  topic_id uuid NOT NULL REFERENCES market_intelligence.topics(id) ON DELETE CASCADE,
  relevance numeric(4,3) NOT NULL DEFAULT 1 CHECK (relevance BETWEEN 0 AND 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (keyword_id, topic_id)
);

CREATE TABLE market_intelligence.search_metrics (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  keyword_id uuid NOT NULL REFERENCES market_intelligence.keywords(id) ON DELETE CASCADE,
  source_id uuid NOT NULL REFERENCES market_intelligence.sources(id) ON DELETE RESTRICT,
  observed_on date NOT NULL,
  granularity text NOT NULL DEFAULT 'day' CHECK (granularity IN ('day', 'week', 'month')),
  country_code text CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$'),
  device text CHECK (device IS NULL OR device IN ('desktop', 'mobile', 'tablet', 'other')),
  dimension_key text GENERATED ALWAYS AS (coalesce(country_code, '*') || ':' || coalesce(device, '*')) STORED,
  impressions bigint CHECK (impressions IS NULL OR impressions >= 0),
  clicks bigint CHECK (clicks IS NULL OR clicks >= 0),
  search_volume bigint CHECK (search_volume IS NULL OR search_volume >= 0),
  ctr numeric(8,6) CHECK (ctr IS NULL OR ctr BETWEEN 0 AND 1),
  average_position numeric(10,4) CHECK (average_position IS NULL OR average_position >= 0),
  cpc numeric(12,4) CHECK (cpc IS NULL OR cpc >= 0),
  competition numeric(5,4) CHECK (competition IS NULL OR competition BETWEEN 0 AND 1),
  trend_score numeric(6,2) CHECK (trend_score IS NULL OR trend_score BETWEEN -100 AND 100),
  confidence numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  data_nature market_intelligence.data_nature NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (keyword_id, source_id, observed_on, granularity, dimension_key)
);

CREATE TABLE market_intelligence.search_results_snapshots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  keyword_id uuid NOT NULL REFERENCES market_intelligence.keywords(id) ON DELETE CASCADE,
  source_id uuid NOT NULL REFERENCES market_intelligence.sources(id) ON DELETE RESTRICT,
  captured_at timestamptz NOT NULL,
  country_code text CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$'),
  device text,
  result_count bigint CHECK (result_count IS NULL OR result_count >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (keyword_id, source_id, captured_at, country_code, device)
);

CREATE TABLE market_intelligence.domains (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  domain text NOT NULL UNIQUE CHECK (domain = lower(domain)),
  display_name text,
  owner_brand text,
  category text,
  is_tippos boolean NOT NULL DEFAULT false,
  authority_score numeric(5,2) CHECK (authority_score IS NULL OR authority_score BETWEEN 0 AND 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.search_result_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  snapshot_id uuid NOT NULL REFERENCES market_intelligence.search_results_snapshots(id) ON DELETE CASCADE,
  rank integer NOT NULL CHECK (rank > 0),
  url text NOT NULL,
  canonical_url text NOT NULL,
  domain_id uuid REFERENCES market_intelligence.domains(id) ON DELETE SET NULL,
  title text,
  snippet text,
  result_type text NOT NULL DEFAULT 'organic',
  is_tippos boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (snapshot_id, rank, result_type)
);

CREATE TABLE market_intelligence.brands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  brand_key text NOT NULL UNIQUE,
  display_name text NOT NULL,
  category text NOT NULL DEFAULT 'competitor',
  is_tippos boolean NOT NULL DEFAULT false,
  aliases text[] NOT NULL DEFAULT '{}',
  evidence_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.ai_prompt_sets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  set_key text NOT NULL UNIQUE,
  display_name text NOT NULL,
  description text,
  active boolean NOT NULL DEFAULT true,
  schedule text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.ai_prompts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  prompt_set_id uuid NOT NULL REFERENCES market_intelligence.ai_prompt_sets(id) ON DELETE CASCADE,
  prompt_key text NOT NULL UNIQUE,
  version integer NOT NULL DEFAULT 1 CHECK (version > 0),
  prompt_text text NOT NULL CHECK (length(prompt_text) BETWEEN 5 AND 4000),
  language_code text NOT NULL REFERENCES market_intelligence.languages(code) ON DELETE RESTRICT,
  country_code text CHECK (country_code IS NULL OR country_code ~ '^[A-Z]{2}$'),
  persona text,
  topic_id uuid REFERENCES market_intelligence.topics(id) ON DELETE SET NULL,
  use_case text,
  funnel_stage text NOT NULL DEFAULT 'awareness' CHECK (funnel_stage IN ('awareness', 'consideration', 'conversion', 'retention')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (prompt_set_id, prompt_key, version)
);

CREATE TABLE market_intelligence.ai_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES market_intelligence.sources(id) ON DELETE RESTRICT,
  prompt_id uuid NOT NULL REFERENCES market_intelligence.ai_prompts(id) ON DELETE RESTRICT,
  idempotency_key text NOT NULL,
  provider_model text NOT NULL,
  model_version text,
  status text NOT NULL CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'blocked_policy')),
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  latency_ms integer CHECK (latency_ms IS NULL OR latency_ms >= 0),
  input_tokens integer CHECK (input_tokens IS NULL OR input_tokens >= 0),
  output_tokens integer CHECK (output_tokens IS NULL OR output_tokens >= 0),
  cost_usd numeric(12,6) CHECK (cost_usd IS NULL OR cost_usd >= 0),
  response_hash text,
  error_code text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source_id, idempotency_key)
);

CREATE TABLE market_intelligence.ai_responses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL UNIQUE REFERENCES market_intelligence.ai_runs(id) ON DELETE CASCADE,
  full_text text,
  structured_summary jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(structured_summary) = 'object'),
  detected_language_code text REFERENCES market_intelligence.languages(code) ON DELETE SET NULL,
  retention_mode text NOT NULL DEFAULT 'summary' CHECK (retention_mode IN ('full', 'summary', 'metadata_only')),
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (retention_mode <> 'metadata_only' OR full_text IS NULL)
);

CREATE TABLE market_intelligence.ai_mentions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES market_intelligence.ai_runs(id) ON DELETE CASCADE,
  brand_id uuid NOT NULL REFERENCES market_intelligence.brands(id) ON DELETE CASCADE,
  mention_position integer CHECK (mention_position IS NULL OR mention_position > 0),
  sentiment numeric(4,3) CHECK (sentiment IS NULL OR sentiment BETWEEN -1 AND 1),
  recommendation_strength numeric(4,3) CHECK (recommendation_strength IS NULL OR recommendation_strength BETWEEN 0 AND 1),
  context_summary text,
  confidence numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (run_id, brand_id, mention_position)
);

CREATE TABLE market_intelligence.ai_citations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES market_intelligence.ai_runs(id) ON DELETE CASCADE,
  citation_order integer NOT NULL CHECK (citation_order > 0),
  url text NOT NULL,
  canonical_url text NOT NULL,
  domain_id uuid REFERENCES market_intelligence.domains(id) ON DELETE SET NULL,
  title text,
  is_tippos boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (run_id, citation_order)
);

CREATE TABLE market_intelligence.content_assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_url text NOT NULL UNIQUE,
  title text NOT NULL,
  language_code text NOT NULL REFERENCES market_intelligence.languages(code) ON DELETE RESTRICT,
  topic_id uuid REFERENCES market_intelligence.topics(id) ON DELETE SET NULL,
  content_type text NOT NULL,
  published_at timestamptz,
  last_indexed_at timestamptz,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.score_definitions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  score_key text NOT NULL,
  version integer NOT NULL CHECK (version > 0),
  description text NOT NULL,
  formula jsonb NOT NULL CHECK (jsonb_typeof(formula) = 'object'),
  active_from timestamptz NOT NULL DEFAULT now(),
  retired_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (score_key, version)
);

CREATE TABLE market_intelligence.language_market_scores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  language_code text NOT NULL REFERENCES market_intelligence.languages(code) ON DELETE CASCADE,
  period_start date NOT NULL,
  period_end date NOT NULL,
  demand_score numeric(5,2) NOT NULL CHECK (demand_score BETWEEN 0 AND 100),
  growth_score numeric(5,2) NOT NULL CHECK (growth_score BETWEEN 0 AND 100),
  business_relevance_score numeric(5,2) NOT NULL CHECK (business_relevance_score BETWEEN 0 AND 100),
  ai_visibility_score numeric(5,2) NOT NULL CHECK (ai_visibility_score BETWEEN 0 AND 100),
  competition_opportunity_score numeric(5,2) NOT NULL CHECK (competition_opportunity_score BETWEEN 0 AND 100),
  data_coverage_score numeric(5,2) NOT NULL CHECK (data_coverage_score BETWEEN 0 AND 100),
  localization_effort_score numeric(5,2) NOT NULL CHECK (localization_effort_score BETWEEN 0 AND 100),
  total_opportunity_score numeric(5,2) NOT NULL CHECK (total_opportunity_score BETWEEN 0 AND 100),
  confidence numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  recommendation market_intelligence.language_recommendation NOT NULL,
  rationale jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(rationale) = 'object'),
  score_definition_version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (language_code, period_start, period_end),
  CHECK (period_end >= period_start)
);

CREATE TABLE market_intelligence.language_rollout_readiness (
  language_code text PRIMARY KEY REFERENCES market_intelligence.languages(code) ON DELETE CASCADE,
  product_copy_status text NOT NULL DEFAULT 'not_started' CHECK (product_copy_status IN ('not_started', 'in_progress', 'ready', 'blocked')),
  legal_copy_status text NOT NULL DEFAULT 'not_started' CHECK (legal_copy_status IN ('not_started', 'in_progress', 'ready', 'blocked')),
  payment_market_status text NOT NULL DEFAULT 'not_evaluated' CHECK (payment_market_status IN ('not_evaluated', 'supported', 'unsupported', 'blocked')),
  native_review_status text NOT NULL DEFAULT 'not_started' CHECK (native_review_status IN ('not_started', 'in_progress', 'approved', 'changes_requested')),
  rtl_validation_status text NOT NULL DEFAULT 'not_required' CHECK (rtl_validation_status IN ('not_required', 'not_started', 'in_progress', 'approved', 'blocked')),
  seo_content_status text NOT NULL DEFAULT 'not_started' CHECK (seo_content_status IN ('not_started', 'in_progress', 'ready', 'blocked')),
  rollout_owner text,
  target_date date,
  blocking_reasons jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(blocking_reasons) = 'array'),
  approved_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((approved_at IS NULL) = (approved_by IS NULL))
);

CREATE TABLE market_intelligence.content_opportunities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  keyword_id uuid REFERENCES market_intelligence.keywords(id) ON DELETE SET NULL,
  topic_id uuid REFERENCES market_intelligence.topics(id) ON DELETE SET NULL,
  language_code text NOT NULL REFERENCES market_intelligence.languages(code) ON DELETE RESTRICT,
  reason text NOT NULL,
  demand_score numeric(5,2) CHECK (demand_score BETWEEN 0 AND 100),
  difficulty_score numeric(5,2) CHECK (difficulty_score BETWEEN 0 AND 100),
  business_relevance_score numeric(5,2) CHECK (business_relevance_score BETWEEN 0 AND 100),
  ai_visibility_gap_score numeric(5,2) CHECK (ai_visibility_gap_score BETWEEN 0 AND 100),
  priority_score numeric(5,2) NOT NULL CHECK (priority_score BETWEEN 0 AND 100),
  recommended_format text,
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'accepted', 'in_progress', 'published', 'dismissed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.daily_aggregates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aggregate_date date NOT NULL,
  dimension_type text NOT NULL,
  dimension_key text NOT NULL,
  metrics jsonb NOT NULL CHECK (jsonb_typeof(metrics) = 'object'),
  score_definition_version integer NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (aggregate_date, dimension_type, dimension_key)
);

CREATE TABLE market_intelligence.alerts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_type text NOT NULL,
  severity text NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'acknowledged', 'resolved', 'dismissed')),
  entity_type text,
  entity_id uuid,
  title text NOT NULL,
  details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  detected_at timestamptz NOT NULL DEFAULT now(),
  acknowledged_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.data_quality_issues (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid REFERENCES market_intelligence.sources(id) ON DELETE SET NULL,
  job_id uuid REFERENCES market_intelligence.collection_jobs(id) ON DELETE SET NULL,
  issue_code text NOT NULL,
  severity text NOT NULL CHECK (severity IN ('info', 'warning', 'error')),
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'quarantined', 'resolved', 'ignored')),
  record_reference text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  detected_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE market_intelligence.audit_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_role text NOT NULL,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Query-path indexes.
CREATE INDEX collection_jobs_status_requested_idx ON market_intelligence.collection_jobs(status, requested_at);
CREATE INDEX raw_observations_expiry_idx ON market_intelligence.raw_observations(expires_at);
CREATE INDEX keywords_language_active_idx ON market_intelligence.keywords(language_code, active);
CREATE INDEX keywords_intent_idx ON market_intelligence.keywords(intent, funnel_stage);
CREATE INDEX search_metrics_observed_idx ON market_intelligence.search_metrics(observed_on DESC, source_id);
CREATE INDEX search_metrics_keyword_date_idx ON market_intelligence.search_metrics(keyword_id, observed_on DESC);
CREATE INDEX ai_runs_prompt_date_idx ON market_intelligence.ai_runs(prompt_id, started_at DESC);
CREATE INDEX ai_mentions_brand_idx ON market_intelligence.ai_mentions(brand_id, created_at DESC);
CREATE INDEX ai_citations_domain_idx ON market_intelligence.ai_citations(domain_id, created_at DESC);
CREATE INDEX language_scores_rank_idx ON market_intelligence.language_market_scores(period_end DESC, total_opportunity_score DESC);
CREATE INDEX language_rollout_target_idx ON market_intelligence.language_rollout_readiness(target_date) WHERE target_date IS NOT NULL;
CREATE INDEX content_opportunities_priority_idx ON market_intelligence.content_opportunities(status, priority_score DESC);
CREATE INDEX alerts_open_idx ON market_intelligence.alerts(severity, detected_at DESC) WHERE status = 'open';
CREATE INDEX data_quality_open_idx ON market_intelligence.data_quality_issues(severity, detected_at DESC) WHERE status IN ('open', 'quarantined');

-- Keep mutable rows timestamped consistently.
DO $triggers$
DECLARE
  v_table text;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'access_roles','languages','sources','connector_accounts','connector_configs',
    'collection_jobs','topics','keywords','domains','brands','ai_prompt_sets','ai_prompts',
    'ai_runs','content_assets','language_market_scores','language_rollout_readiness','content_opportunities',
    'daily_aggregates','alerts','data_quality_issues'
  ]
  LOOP
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON market_intelligence.%I FOR EACH ROW EXECUTE FUNCTION market_intelligence.set_updated_at()',
      v_table || '_set_updated_at', v_table
    );
  END LOOP;
END
$triggers$;

-- Defense in depth: no client role receives raw-table privileges.
DO $rls$
DECLARE
  v_table text;
BEGIN
  FOR v_table IN
    SELECT tablename FROM pg_tables WHERE schemaname = 'market_intelligence'
  LOOP
    EXECUTE format('ALTER TABLE market_intelligence.%I ENABLE ROW LEVEL SECURITY', v_table);
    EXECUTE format('CREATE POLICY %I ON market_intelligence.%I FOR ALL TO service_role USING (true) WITH CHECK (true)',
      v_table || '_service_role_all', v_table);
  END LOOP;
END
$rls$;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA market_intelligence TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA market_intelligence TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA market_intelligence
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA market_intelligence
  GRANT USAGE, SELECT ON SEQUENCES TO service_role;
REVOKE ALL ON ALL TABLES IN SCHEMA market_intelligence FROM PUBLIC, anon, authenticated;

-- Analysts may see their own assigned role but cannot grant roles.
GRANT USAGE ON SCHEMA market_intelligence TO authenticated;
GRANT SELECT ON market_intelligence.access_roles TO authenticated;
CREATE POLICY access_roles_read_self ON market_intelligence.access_roles
  FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE VIEW market_intelligence.v_keyword_opportunities
WITH (security_invoker = true)
AS
SELECT
  k.id AS keyword_id,
  k.original_text,
  k.language_code,
  k.intent,
  k.funnel_stage,
  k.business_relevance,
  coalesce(sum(sm.search_volume), 0) AS search_volume,
  coalesce(sum(sm.impressions), 0) AS impressions,
  coalesce(sum(sm.clicks), 0) AS clicks,
  round(avg(sm.trend_score), 2) AS average_trend,
  round(avg(sm.competition) * 100, 2) AS competition_percent,
  max(sm.observed_on) AS freshest_observation
FROM market_intelligence.keywords k
LEFT JOIN market_intelligence.search_metrics sm ON sm.keyword_id = k.id
GROUP BY k.id;

CREATE VIEW market_intelligence.v_ai_visibility
WITH (security_invoker = true)
AS
SELECT
  p.language_code,
  r.provider_model,
  date_trunc('day', r.started_at)::date AS run_date,
  count(*) FILTER (WHERE r.status = 'succeeded') AS successful_runs,
  count(DISTINCT r.id) FILTER (WHERE b.is_tippos) AS tippos_mentions,
  round(100.0 * count(DISTINCT r.id) FILTER (WHERE b.is_tippos)
    / nullif(count(DISTINCT r.id) FILTER (WHERE r.status = 'succeeded'), 0), 2) AS visibility_percent
FROM market_intelligence.ai_runs r
JOIN market_intelligence.ai_prompts p ON p.id = r.prompt_id
LEFT JOIN market_intelligence.ai_mentions m ON m.run_id = r.id
LEFT JOIN market_intelligence.brands b ON b.id = m.brand_id
GROUP BY p.language_code, r.provider_model, date_trunc('day', r.started_at)::date;

CREATE VIEW market_intelligence.v_data_freshness
WITH (security_invoker = true)
AS
SELECT
  s.source_key,
  s.display_name,
  s.status,
  s.last_success_at,
  max(j.finished_at) FILTER (WHERE j.status IN ('succeeded', 'partially_succeeded')) AS latest_job,
  count(*) FILTER (WHERE j.status = 'failed' AND j.requested_at > now() - interval '7 days') AS failures_7d
FROM market_intelligence.sources s
LEFT JOIN market_intelligence.collection_jobs j ON j.source_id = s.id
GROUP BY s.id;

CREATE VIEW market_intelligence.v_language_recommendations
WITH (security_invoker = true)
AS
SELECT DISTINCT ON (l.code)
  l.code,
  l.english_name,
  l.native_name,
  l.text_direction,
  l.product_status,
  s.period_start,
  s.period_end,
  s.total_opportunity_score,
  s.demand_score,
  s.growth_score,
  s.business_relevance_score,
  s.ai_visibility_score,
  s.competition_opportunity_score,
  s.data_coverage_score,
  s.localization_effort_score,
  s.confidence,
  s.recommendation,
  s.rationale,
  rr.product_copy_status,
  rr.legal_copy_status,
  rr.payment_market_status,
  rr.native_review_status,
  rr.rtl_validation_status,
  rr.seo_content_status,
  rr.rollout_owner,
  rr.target_date,
  rr.blocking_reasons,
  (
    rr.product_copy_status = 'ready'
    AND rr.legal_copy_status = 'ready'
    AND rr.payment_market_status = 'supported'
    AND rr.native_review_status = 'approved'
    AND rr.rtl_validation_status IN ('not_required', 'approved')
    AND rr.seo_content_status = 'ready'
    AND rr.approved_at IS NOT NULL
  ) AS ready_to_release
FROM market_intelligence.languages l
LEFT JOIN market_intelligence.language_market_scores s ON s.language_code = l.code
LEFT JOIN market_intelligence.language_rollout_readiness rr ON rr.language_code = l.code
ORDER BY l.code, s.period_end DESC NULLS LAST;

CREATE VIEW market_intelligence.v_data_dictionary
WITH (security_invoker = true)
AS
SELECT
  c.table_schema,
  c.table_name,
  c.ordinal_position,
  c.column_name,
  c.data_type,
  c.udt_name,
  c.is_nullable,
  c.column_default
FROM information_schema.columns c
WHERE c.table_schema = 'market_intelligence'
ORDER BY c.table_name, c.ordinal_position;

GRANT SELECT ON market_intelligence.v_keyword_opportunities,
  market_intelligence.v_ai_visibility,
  market_intelligence.v_data_freshness,
  market_intelligence.v_language_recommendations,
  market_intelligence.v_data_dictionary TO service_role;

-- Idempotent search-metric ingestion boundary. Payload is validated again in Edge.
CREATE OR REPLACE FUNCTION public.mi_import_search_metrics(
  p_source_key text,
  p_external_job_key text,
  p_observations jsonb,
  p_dry_run boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source market_intelligence.sources%ROWTYPE;
  v_job_id uuid;
  v_item jsonb;
  v_keyword_id uuid;
  v_language text;
  v_country text;
  v_query text;
  v_normalized text;
  v_loaded integer := 0;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_observations) <> 'array' OR jsonb_array_length(p_observations) > 1000 THEN
    RAISE EXCEPTION 'invalid_observations_batch';
  END IF;
  SELECT * INTO v_source FROM market_intelligence.sources WHERE source_key = p_source_key;
  IF NOT FOUND OR v_source.status NOT IN ('enabled', 'mock', 'disabled_pending_credentials') THEN
    RAISE EXCEPTION 'source_not_enabled';
  END IF;

  INSERT INTO market_intelligence.collection_jobs
    (source_id, external_key, job_type, status, dry_run, started_at, metadata)
  VALUES
    (v_source.id, p_external_job_key || CASE WHEN p_dry_run THEN '-dry-run' ELSE '' END,
     'search_metrics_import', 'running', p_dry_run, now(),
     jsonb_build_object('payload_count', jsonb_array_length(p_observations)))
  ON CONFLICT (source_id, external_key) DO UPDATE
    SET updated_at = now()
  RETURNING id INTO v_job_id;

  IF EXISTS (SELECT 1 FROM market_intelligence.collection_jobs WHERE id = v_job_id AND status = 'succeeded') THEN
    RETURN jsonb_build_object('ok', true, 'replayed', true, 'job_id', v_job_id);
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_observations)
  LOOP
    v_query := btrim(v_item->>'query');
    v_normalized := market_intelligence.normalize_text(v_query);
    v_language := v_item->>'language_code';
    v_country := nullif(upper(v_item->>'country_code'), '');
    IF length(v_query) NOT BETWEEN 1 AND 500
      OR NOT EXISTS (SELECT 1 FROM market_intelligence.languages WHERE code = v_language)
      OR (v_country IS NOT NULL AND v_country !~ '^[A-Z]{2}$') THEN
      RAISE EXCEPTION 'invalid_search_observation';
    END IF;

    IF NOT p_dry_run THEN
      INSERT INTO market_intelligence.raw_observations
        (source_id, job_id, external_id, observation_type, event_at, data_nature,
         confidence, checksum, payload, expires_at)
      VALUES
        (v_source.id, v_job_id, v_item->>'external_id', 'search_metric',
         coalesce((v_item->>'event_at')::timestamptz, (v_item->>'observed_on')::date::timestamptz),
         v_source.data_nature, coalesce((v_item->>'confidence')::numeric, v_source.default_confidence),
         md5(v_item::text), v_item, now() + make_interval(days => v_source.retention_days))
      ON CONFLICT (source_id, observation_type, checksum) DO NOTHING;

      INSERT INTO market_intelligence.keywords
        (original_text, normalized_text, language_code, country_code, intent, funnel_stage,
         persona, industry, use_case, is_branded, business_relevance)
      VALUES
        (v_query, v_normalized, v_language, v_country,
         coalesce((v_item->>'intent')::market_intelligence.search_intent, 'unknown'),
         coalesce(v_item->>'funnel_stage', 'unknown'), v_item->>'persona', v_item->>'industry',
         v_item->>'use_case', coalesce((v_item->>'is_branded')::boolean, false),
         coalesce((v_item->>'business_relevance')::numeric, 50))
      ON CONFLICT (normalized_text, language_code, (coalesce(country_code, '*'))) DO UPDATE
        SET business_relevance = greatest(market_intelligence.keywords.business_relevance, EXCLUDED.business_relevance),
            active = true,
            updated_at = now()
      RETURNING id INTO v_keyword_id;

      INSERT INTO market_intelligence.search_metrics
        (keyword_id, source_id, observed_on, granularity, country_code, device,
         impressions, clicks, search_volume, ctr, average_position, cpc, competition,
         trend_score, confidence, data_nature)
      VALUES
        (v_keyword_id, v_source.id, (v_item->>'observed_on')::date,
         coalesce(v_item->>'granularity', 'day'), v_country, nullif(v_item->>'device', ''),
         (v_item->>'impressions')::bigint, (v_item->>'clicks')::bigint,
         (v_item->>'search_volume')::bigint, (v_item->>'ctr')::numeric,
         (v_item->>'average_position')::numeric, (v_item->>'cpc')::numeric,
         (v_item->>'competition')::numeric, (v_item->>'trend_score')::numeric,
         coalesce((v_item->>'confidence')::numeric, v_source.default_confidence), v_source.data_nature)
      ON CONFLICT (keyword_id, source_id, observed_on, granularity, dimension_key) DO UPDATE
        SET impressions = EXCLUDED.impressions, clicks = EXCLUDED.clicks,
            search_volume = EXCLUDED.search_volume, ctr = EXCLUDED.ctr,
            average_position = EXCLUDED.average_position, cpc = EXCLUDED.cpc,
            competition = EXCLUDED.competition, trend_score = EXCLUDED.trend_score,
            confidence = EXCLUDED.confidence, data_nature = EXCLUDED.data_nature,
            updated_at = now();
    END IF;
    v_loaded := v_loaded + 1;
  END LOOP;

  UPDATE market_intelligence.collection_jobs
     SET status = 'succeeded', finished_at = now(), rows_seen = jsonb_array_length(p_observations),
         rows_loaded = v_loaded, rows_rejected = 0
   WHERE id = v_job_id;
  UPDATE market_intelligence.sources SET last_success_at = now() WHERE id = v_source.id;
  IF v_source.status = 'disabled_pending_credentials' THEN
    UPDATE market_intelligence.sources SET status = 'enabled' WHERE id = v_source.id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'replayed', false, 'job_id', v_job_id, 'loaded', v_loaded, 'dry_run', p_dry_run);
END;
$$;

-- Recompute explainable language-market recommendations for a period.
CREATE OR REPLACE FUNCTION public.mi_refresh_language_scores(p_period_start date, p_period_end date)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_period_end < p_period_start OR p_period_end - p_period_start > 366 THEN
    RAISE EXCEPTION 'invalid_score_period';
  END IF;

  WITH search_rollup AS (
    SELECT k.language_code,
      coalesce(sum(sm.search_volume), 0) + coalesce(sum(sm.impressions), 0) AS demand,
      coalesce(avg(sm.trend_score), 0) AS trend,
      coalesce(avg(k.business_relevance), 0) AS relevance,
      coalesce(avg(1 - sm.competition), 0.5) * 100 AS competition_opportunity,
      count(DISTINCT sm.observed_on) AS observed_days,
      avg(sm.confidence) AS source_confidence
    FROM market_intelligence.keywords k
    LEFT JOIN market_intelligence.search_metrics sm
      ON sm.keyword_id = k.id AND sm.observed_on BETWEEN p_period_start AND p_period_end
    GROUP BY k.language_code
  ), ai_rollup AS (
    SELECT p.language_code,
      100.0 * count(DISTINCT r.id) FILTER (WHERE b.is_tippos)
        / nullif(count(DISTINCT r.id) FILTER (WHERE r.status = 'succeeded'), 0) AS visibility,
      count(DISTINCT r.id) FILTER (WHERE r.status = 'succeeded') AS ai_runs
    FROM market_intelligence.ai_prompts p
    LEFT JOIN market_intelligence.ai_runs r ON r.prompt_id = p.id
      AND r.started_at::date BETWEEN p_period_start AND p_period_end
    LEFT JOIN market_intelligence.ai_mentions m ON m.run_id = r.id
    LEFT JOIN market_intelligence.brands b ON b.id = m.brand_id
    GROUP BY p.language_code
  ), scored AS (
    SELECT l.code,
      least(100, round((ln(1 + coalesce(s.demand, 0)) * 8)::numeric, 2)) AS demand_score,
      least(100, greatest(0, round((50 + coalesce(s.trend, 0) / 2)::numeric, 2))) AS growth_score,
      least(100, greatest(0, round(coalesce(s.relevance, 0)::numeric, 2))) AS relevance_score,
      least(100, greatest(0, round(coalesce(a.visibility, 0)::numeric, 2))) AS visibility_score,
      least(100, greatest(0, round(coalesce(s.competition_opportunity, 50)::numeric, 2))) AS competition_score,
      least(100, round((100.0 * least(coalesce(s.observed_days, 0), 30) / 30)::numeric, 2)) AS coverage_score,
      CASE WHEN l.product_status = 'supported' THEN 100
           WHEN l.estimated_localization_cost IS NULL THEN 50
           ELSE greatest(0, least(100, round((100 - l.estimated_localization_cost / 100)::numeric, 2))) END AS effort_score,
      coalesce(s.source_confidence, 0.3) AS confidence,
      coalesce(a.ai_runs, 0) AS ai_runs,
      coalesce(s.observed_days, 0) AS observed_days
    FROM market_intelligence.languages l
    LEFT JOIN search_rollup s ON s.language_code = l.code
    LEFT JOIN ai_rollup a ON a.language_code = l.code
    WHERE l.code <> 'und'
  ), final AS (
    SELECT *, round((
      demand_score * 0.30 + growth_score * 0.15 + relevance_score * 0.20 +
      (100 - visibility_score) * 0.10 + competition_score * 0.10 +
      coverage_score * 0.10 + effort_score * 0.05
    )::numeric, 2) AS total_score
    FROM scored
  )
  INSERT INTO market_intelligence.language_market_scores
    (language_code, period_start, period_end, demand_score, growth_score,
     business_relevance_score, ai_visibility_score, competition_opportunity_score,
     data_coverage_score, localization_effort_score, total_opportunity_score,
     confidence, recommendation, rationale, score_definition_version)
  SELECT f.code, p_period_start, p_period_end, f.demand_score, f.growth_score,
    f.relevance_score, f.visibility_score, f.competition_score, f.coverage_score,
    f.effort_score, f.total_score, least(1, greatest(0, f.confidence)),
    CASE
      WHEN l.product_status = 'supported' THEN 'maintain'::market_intelligence.language_recommendation
      WHEN f.coverage_score < 35 THEN 'validate'::market_intelligence.language_recommendation
      WHEN f.total_score >= 70 AND f.confidence >= 0.6 THEN 'implement'::market_intelligence.language_recommendation
      WHEN f.total_score >= 50 THEN 'validate'::market_intelligence.language_recommendation
      WHEN f.total_score >= 30 THEN 'monitor'::market_intelligence.language_recommendation
      ELSE 'deprioritize'::market_intelligence.language_recommendation
    END,
    jsonb_build_object(
      'observed_days', f.observed_days, 'ai_runs', f.ai_runs,
      'weights', jsonb_build_object('demand', 0.30, 'growth', 0.15, 'business_relevance', 0.20,
        'ai_visibility_gap', 0.10, 'competition_opportunity', 0.10, 'coverage', 0.10, 'localization_effort', 0.05),
      'guardrail', CASE WHEN f.coverage_score < 35 THEN 'insufficient_data_for_implementation' ELSE 'none' END
    ), 1
  FROM final f JOIN market_intelligence.languages l ON l.code = f.code
  ON CONFLICT (language_code, period_start, period_end) DO UPDATE SET
    demand_score = EXCLUDED.demand_score, growth_score = EXCLUDED.growth_score,
    business_relevance_score = EXCLUDED.business_relevance_score,
    ai_visibility_score = EXCLUDED.ai_visibility_score,
    competition_opportunity_score = EXCLUDED.competition_opportunity_score,
    data_coverage_score = EXCLUDED.data_coverage_score,
    localization_effort_score = EXCLUDED.localization_effort_score,
    total_opportunity_score = EXCLUDED.total_opportunity_score,
    confidence = EXCLUDED.confidence, recommendation = EXCLUDED.recommendation,
    rationale = EXCLUDED.rationale, score_definition_version = EXCLUDED.score_definition_version,
    updated_at = now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- Narrow dashboard RPC; users must be explicitly assigned at least viewer.
CREATE OR REPLACE FUNCTION public.mi_get_language_recommendations()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role'
    AND NOT market_intelligence.has_minimum_role('viewer'::market_intelligence.access_role) THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(v) ORDER BY v.total_opportunity_score DESC NULLS LAST), '[]'::jsonb)
    INTO v_result FROM market_intelligence.v_language_recommendations v;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION market_intelligence.set_updated_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION market_intelligence.normalize_text(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION market_intelligence.normalize_text(text) TO service_role;
REVOKE ALL ON FUNCTION market_intelligence.has_minimum_role(market_intelligence.access_role) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION market_intelligence.has_minimum_role(market_intelligence.access_role) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.mi_import_search_metrics(text, text, jsonb, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_import_search_metrics(text, text, jsonb, boolean) TO service_role;
REVOKE ALL ON FUNCTION public.mi_refresh_language_scores(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_refresh_language_scores(date, date) TO service_role;
REVOKE ALL ON FUNCTION public.mi_get_language_recommendations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mi_get_language_recommendations() TO authenticated, service_role;
