-- Live sales-tax rates for the brand site's tax-and-tip calculator.
-- Written only by the market-intelligence-sales-tax function (service role),
-- read publicly through the same function. One row per state plus DC, always
-- the newest Tax Foundation edition that passed every check.

CREATE TABLE IF NOT EXISTS public.sales_tax_rates (
  state text PRIMARY KEY,
  state_rate numeric(5, 3) NOT NULL CHECK (state_rate >= 0 AND state_rate <= 12),
  local_rate numeric(5, 3) NOT NULL,
  combined_rate numeric(5, 3) NOT NULL CHECK (combined_rate >= 0 AND combined_rate <= 15),
  edition text NOT NULL,
  as_of date NOT NULL,
  source_url text NOT NULL,
  fetched_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.sales_tax_rates ENABLE ROW LEVEL SECURITY;
-- No policies: anon and authenticated cannot read or write the table directly.
REVOKE ALL ON public.sales_tax_rates FROM anon, authenticated;

-- Monthly refresh on the 3rd at 08:30 UTC. Tax Foundation publishes in January
-- and July, so most runs re-read an unchanged table; that is the point — a
-- new edition shows up within a month without anyone remembering to check.
DO $$
DECLARE v_job_id bigint;
BEGIN
  FOR v_job_id IN SELECT jobid FROM cron.job WHERE jobname = 'tippos-mi-sales-tax-monthly'
  LOOP PERFORM cron.unschedule(v_job_id); END LOOP;
END;
$$;

SELECT cron.schedule(
  'tippos-mi-sales-tax-monthly',
  '30 8 3 * *',
  $job$
    WITH config AS (
      SELECT
        max(decrypted_secret) FILTER (WHERE name = 'mi_project_url') AS project_url,
        max(decrypted_secret) FILTER (WHERE name = 'mi_service_role_jwt') AS service_role_jwt
      FROM vault.decrypted_secrets
      WHERE name IN ('mi_project_url', 'mi_service_role_jwt')
    )
    SELECT net.http_post(
      url := rtrim(project_url, '/') || '/functions/v1/market-intelligence-sales-tax',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'apikey', service_role_jwt,
        'Authorization', 'Bearer ' || service_role_jwt
      ),
      body := '{"automatic":true}'::jsonb,
      timeout_milliseconds := 55000
    )
    FROM config
    WHERE project_url IS NOT NULL AND service_role_jwt IS NOT NULL;
  $job$
);
