-- Bound and audit access-code use for the private strategy assistant.
-- Raw client addresses are never stored; Edge sends only a salted SHA-256 hash.

CREATE TABLE market_intelligence.strategy_access_attempts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  client_hash text NOT NULL
    CHECK (client_hash ~ '^[0-9a-f]{64}$'),
  succeeded boolean NOT NULL,
  action text NOT NULL DEFAULT 'request'
    CHECK (action IN ('request', 'rate_limited')),
  attempted_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE market_intelligence.strategy_access_attempts ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON market_intelligence.strategy_access_attempts
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON SEQUENCE market_intelligence.strategy_access_attempts_id_seq
  FROM PUBLIC, anon, authenticated, service_role;

CREATE INDEX strategy_access_attempts_client_window_idx
  ON market_intelligence.strategy_access_attempts (client_hash, attempted_at DESC);

CREATE INDEX strategy_access_attempts_request_window_idx
  ON market_intelligence.strategy_access_attempts (attempted_at DESC)
  WHERE action = 'request';

CREATE OR REPLACE FUNCTION public.mi_reserve_strategy_access_attempt(
  p_client_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_failed_fifteen_minutes bigint;
  v_client_hour bigint;
  v_global_request_hour bigint;
  v_attempt_id bigint;
  v_denial_reason text;
  v_retry_after_seconds integer;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_client_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_strategy_client_hash' USING ERRCODE = '22023';
  END IF;

  -- Serialize the small private-assistant admission boundary so concurrent
  -- requests cannot all pass before any reservation is visible.
  PERFORM pg_advisory_xact_lock(hashtext('tippos-mi-strategy-access'));

  SELECT count(*)
    INTO v_failed_fifteen_minutes
    FROM market_intelligence.strategy_access_attempts
   WHERE client_hash = p_client_hash
     AND NOT succeeded
     AND action = 'request'
     AND attempted_at >= now() - interval '15 minutes';

  SELECT count(*)
    INTO v_client_hour
    FROM market_intelligence.strategy_access_attempts
   WHERE client_hash = p_client_hash
     AND action = 'request'
     AND attempted_at >= now() - interval '1 hour';

  SELECT count(*)
    INTO v_global_request_hour
    FROM market_intelligence.strategy_access_attempts
   WHERE action = 'request'
     AND attempted_at >= now() - interval '1 hour';

  IF v_failed_fifteen_minutes >= 8 THEN
    v_denial_reason := 'too_many_failures';
    v_retry_after_seconds := 900;
  ELSIF v_client_hour >= 30 THEN
    v_denial_reason := 'client_hourly_limit';
    v_retry_after_seconds := 3600;
  ELSIF v_global_request_hour >= 200 THEN
    v_denial_reason := 'global_hourly_limit';
    v_retry_after_seconds := 3600;
  END IF;

  IF v_denial_reason IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1
        FROM market_intelligence.strategy_access_attempts
       WHERE client_hash = p_client_hash
         AND action = 'rate_limited'
         AND attempted_at >= now() - interval '1 minute'
    ) THEN
      INSERT INTO market_intelligence.strategy_access_attempts (
        client_hash,
        succeeded,
        action
      )
      VALUES (p_client_hash, false, 'rate_limited');
    END IF;
    RETURN jsonb_build_object(
      'allowed', false,
      'reason', v_denial_reason,
      'retry_after_seconds', v_retry_after_seconds
    );
  END IF;

  INSERT INTO market_intelligence.strategy_access_attempts (
    client_hash,
    succeeded,
    action
  )
  VALUES (p_client_hash, false, 'request')
  RETURNING id INTO v_attempt_id;

  RETURN jsonb_build_object(
    'allowed', true,
    'attempt_id', v_attempt_id,
    'retry_after_seconds', 0
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.mi_finalize_strategy_access_attempt(
  p_attempt_id bigint,
  p_client_hash text,
  p_succeeded boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_client_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid_strategy_client_hash' USING ERRCODE = '22023';
  END IF;
  IF p_attempt_id IS NULL OR p_attempt_id <= 0 THEN
    RAISE EXCEPTION 'invalid_strategy_attempt_id' USING ERRCODE = '22023';
  END IF;

  UPDATE market_intelligence.strategy_access_attempts
     SET succeeded = p_succeeded
   WHERE id = p_attempt_id
     AND client_hash = p_client_hash
     AND action = 'request'
     AND attempted_at >= now() - interval '5 minutes';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'strategy_attempt_not_found' USING ERRCODE = 'P0002';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.mi_reserve_strategy_access_attempt(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_reserve_strategy_access_attempt(text)
  TO service_role;
REVOKE ALL ON FUNCTION public.mi_finalize_strategy_access_attempt(bigint, text, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_finalize_strategy_access_attempt(bigint, text, boolean)
  TO service_role;

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  FOR v_job_id IN
    SELECT jobid
      FROM cron.job
     WHERE jobname = 'tippos-mi-strategy-access-cleanup'
  LOOP
    PERFORM cron.unschedule(v_job_id);
  END LOOP;
END;
$$;

SELECT cron.schedule(
  'tippos-mi-strategy-access-cleanup',
  '35 3 * * *',
  $job$
    DELETE FROM market_intelligence.strategy_access_attempts
     WHERE attempted_at < now() - interval '30 days';
  $job$
);
