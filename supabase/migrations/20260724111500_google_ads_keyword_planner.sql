-- Register Google Ads Keyword Planner historical demand estimates.
-- These are real provider observations, but Google describes the counts as
-- approximate and may combine close variants, so they remain third-party
-- evidence rather than first-party measured behavior.
INSERT INTO market_intelligence.sources
  (source_key, display_name, kind, status, base_url, documentation_url, terms_url,
   collection_method, data_nature, default_confidence, retention_days, config_schema)
VALUES
  ('google_ads_keyword_planner', 'Google Ads Keyword Planner Historical Metrics', 'keyword_provider',
   'disabled_pending_credentials', 'https://googleads.googleapis.com',
   'https://developers.google.com/google-ads/api/docs/keyword-planning/generate-historical-metrics',
   'https://developers.google.com/terms/site-terms',
   'official_api', 'third_party', 0.800, 730,
   jsonb_build_object(
     'metric', 'approximate_monthly_searches',
     'country_code', 'US',
     'language_code', 'en',
     'network', 'GOOGLE_SEARCH',
     'close_variants_may_be_aggregated', true,
     'counts_unique_people', false,
     'refresh_cadence', 'monthly'
   ))
ON CONFLICT (source_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  kind = EXCLUDED.kind,
  base_url = EXCLUDED.base_url,
  documentation_url = EXCLUDED.documentation_url,
  terms_url = EXCLUDED.terms_url,
  collection_method = EXCLUDED.collection_method,
  data_nature = EXCLUDED.data_nature,
  default_confidence = EXCLUDED.default_confidence,
  retention_days = EXCLUDED.retention_days,
  config_schema = EXCLUDED.config_schema,
  updated_at = now();

DO $$
DECLARE v_job_id bigint;
BEGIN
  FOR v_job_id IN SELECT jobid FROM cron.job WHERE jobname = 'tippos-mi-google-ads-monthly'
  LOOP PERFORM cron.unschedule(v_job_id); END LOOP;
END;
$$;

SELECT cron.schedule(
  'tippos-mi-google-ads-monthly',
  '15 9 2 * *',
  $job$
    WITH config AS (
      SELECT
        max(decrypted_secret) FILTER (WHERE name = 'mi_project_url') AS project_url,
        max(decrypted_secret) FILTER (WHERE name = 'mi_service_role_jwt') AS service_role_jwt
      FROM vault.decrypted_secrets
      WHERE name IN ('mi_project_url', 'mi_service_role_jwt')
    )
    SELECT net.http_post(
      url := rtrim(project_url, '/') || '/functions/v1/market-intelligence-google-ads-sync',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'apikey', service_role_jwt,
        'Authorization', 'Bearer ' || service_role_jwt,
        'Idempotency-Key', 'google-ads-auto-' || to_char(current_date, 'YYYYMM')
      ),
      body := '{"automatic":true}'::jsonb,
      timeout_milliseconds := 55000
    )
    FROM config
    WHERE project_url IS NOT NULL AND service_role_jwt IS NOT NULL;
  $job$
);
