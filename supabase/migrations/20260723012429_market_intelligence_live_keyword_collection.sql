-- Collect measured TIPPOS keyword performance from Google Search Console daily.
-- The HTTP job remains dormant until both required Vault secrets are configured.

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.mi_record_collection_failure(
  p_source_key text,
  p_external_job_key text,
  p_error_code text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source_id uuid;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_external_job_key !~ '^[a-z0-9][a-z0-9_-]{1,199}$'
     OR p_error_code !~ '^[a-z0-9_]{1,100}$' THEN
    RAISE EXCEPTION 'invalid_collection_failure';
  END IF;

  SELECT id INTO v_source_id FROM market_intelligence.sources WHERE source_key = p_source_key;
  IF v_source_id IS NULL THEN RAISE EXCEPTION 'unknown_source'; END IF;

  INSERT INTO market_intelligence.collection_jobs
    (source_id, external_key, job_type, status, started_at, finished_at, error_code, error_summary)
  VALUES
    (v_source_id, p_external_job_key, 'search_metrics_import', 'failed', now(), now(),
     p_error_code, 'Provider collection failed; inspect Edge Function logs.')
  ON CONFLICT (source_id, external_key) DO UPDATE
    SET status = 'failed', finished_at = now(), error_code = EXCLUDED.error_code,
        error_summary = EXCLUDED.error_summary, updated_at = now();
END;
$$;

REVOKE ALL ON FUNCTION public.mi_record_collection_failure(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_record_collection_failure(text, text, text) TO service_role;

DO $$
DECLARE v_job_id bigint;
BEGIN
  FOR v_job_id IN SELECT jobid FROM cron.job WHERE jobname = 'tippos-mi-gsc-keywords-daily'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;
END;
$$;

SELECT cron.schedule(
  'tippos-mi-gsc-keywords-daily',
  '30 8 * * *',
  $job$
    WITH config AS (
      SELECT
        max(decrypted_secret) FILTER (WHERE name = 'mi_project_url') AS project_url,
        max(decrypted_secret) FILTER (WHERE name = 'mi_service_role_jwt') AS service_role_jwt
      FROM vault.decrypted_secrets
      WHERE name IN ('mi_project_url', 'mi_service_role_jwt')
    )
    SELECT net.http_post(
      url := rtrim(project_url, '/') || '/functions/v1/market-intelligence-gsc-sync',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'apikey', service_role_jwt,
        'Authorization', 'Bearer ' || service_role_jwt,
        'Idempotency-Key', 'gsc-auto-' || to_char(current_date, 'YYYYMMDD')
      ),
      body := '{"automatic":true}'::jsonb,
      timeout_milliseconds := 55000
    )
    FROM config
    WHERE project_url IS NOT NULL AND service_role_jwt IS NOT NULL;
  $job$
);
