-- A validated dry run or an empty provider response is not landed evidence.
-- Keep the audit job, but only advance source success state after at least one
-- real observation was written.
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
  v_validated integer := 0;
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

    v_validated := v_validated + 1;
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
      v_loaded := v_loaded + 1;
    END IF;
  END LOOP;

  UPDATE market_intelligence.collection_jobs
     SET status = 'succeeded', finished_at = now(), rows_seen = v_validated,
         rows_loaded = v_loaded, rows_rejected = 0
   WHERE id = v_job_id;

  IF NOT p_dry_run AND v_loaded > 0 THEN
    UPDATE market_intelligence.sources SET last_success_at = now() WHERE id = v_source.id;
    IF v_source.status = 'disabled_pending_credentials' THEN
      UPDATE market_intelligence.sources SET status = 'enabled' WHERE id = v_source.id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'replayed', false,
    'job_id', v_job_id,
    'validated', v_validated,
    'loaded', v_loaded,
    'dry_run', p_dry_run,
    'evidence_landed', (NOT p_dry_run AND v_loaded > 0)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.mi_import_search_metrics(text, text, jsonb, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_import_search_metrics(text, text, jsonb, boolean)
  TO service_role;
