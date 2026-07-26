-- Automate internal Market Intelligence maintenance without invoking paid providers.

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

GRANT USAGE ON SCHEMA cron TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA cron TO postgres;

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  FOR v_job_id IN
    SELECT jobid
    FROM cron.job
    WHERE jobname IN (
      'tippos-mi-cleanup-weekly',
      'tippos-mi-score-previous-month'
    )
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;
END;
$$;

SELECT cron.schedule(
  'tippos-mi-cleanup-weekly',
  '15 3 * * 0',
  $job$
    SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
    SELECT public.mi_cleanup_expired_data();
  $job$
);

SELECT cron.schedule(
  'tippos-mi-score-previous-month',
  '0 4 1 * *',
  $job$
    SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
    SELECT public.mi_refresh_language_scores(
      (date_trunc('month', current_date) - interval '1 month')::date,
      (date_trunc('month', current_date) - interval '1 day')::date
    );
  $job$
);
