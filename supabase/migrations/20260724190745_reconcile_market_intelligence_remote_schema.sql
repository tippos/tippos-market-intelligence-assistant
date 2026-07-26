-- Forward-only convergence for changes that differ from the canonical hosted history.
-- Re-applying CREATE OR REPLACE definitions is intentional and idempotent.
-- This migration must remain after every migration currently recorded on the hosted project.

-- AI visibility ingestion and retention maintenance.

CREATE OR REPLACE FUNCTION public.mi_record_ai_visibility(
  p_source_key text,
  p_prompt_key text,
  p_idempotency_key text,
  p_provider_model text,
  p_status text,
  p_response_summary jsonb,
  p_response_text text,
  p_retention_mode text,
  p_mentions jsonb,
  p_citations jsonb,
  p_metrics jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source market_intelligence.sources%ROWTYPE;
  v_prompt market_intelligence.ai_prompts%ROWTYPE;
  v_run_id uuid;
  v_item jsonb;
  v_brand_id uuid;
  v_domain_id uuid;
  v_domain text;
  v_url text;
  v_existing_status text;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  IF length(p_idempotency_key) NOT BETWEEN 8 AND 200
    OR length(p_provider_model) NOT BETWEEN 2 AND 200
    OR p_status NOT IN ('succeeded', 'failed', 'blocked_policy')
    OR p_retention_mode NOT IN ('full', 'summary', 'metadata_only')
    OR jsonb_typeof(p_response_summary) <> 'object'
    OR jsonb_typeof(p_mentions) <> 'array'
    OR jsonb_typeof(p_citations) <> 'array'
    OR jsonb_array_length(p_mentions) > 100
    OR jsonb_array_length(p_citations) > 100 THEN
    RAISE EXCEPTION 'invalid_ai_visibility_payload';
  END IF;
  IF p_retention_mode <> 'full' AND p_response_text IS NOT NULL THEN
    RAISE EXCEPTION 'full_text_not_allowed_for_retention_mode';
  END IF;

  SELECT * INTO v_source
    FROM market_intelligence.sources
   WHERE source_key = p_source_key AND kind IN ('ai_provider', 'synthetic');
  IF NOT FOUND OR v_source.status NOT IN ('enabled', 'mock', 'disabled_pending_credentials') THEN
    RAISE EXCEPTION 'source_not_enabled';
  END IF;
  SELECT * INTO v_prompt
    FROM market_intelligence.ai_prompts
   WHERE prompt_key = p_prompt_key AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'prompt_not_found'; END IF;

  SELECT id, status INTO v_run_id, v_existing_status
    FROM market_intelligence.ai_runs
   WHERE source_id = v_source.id AND idempotency_key = p_idempotency_key;
  IF FOUND AND v_existing_status = 'succeeded' THEN
    RETURN jsonb_build_object('ok', true, 'replayed', true, 'run_id', v_run_id);
  END IF;

  INSERT INTO market_intelligence.ai_runs
    (source_id, prompt_id, idempotency_key, provider_model, model_version, status,
     finished_at, latency_ms, input_tokens, output_tokens, cost_usd, response_hash, error_code)
  VALUES
    (v_source.id, v_prompt.id, p_idempotency_key, p_provider_model, p_metrics->>'model_version', p_status,
     now(), (p_metrics->>'latency_ms')::integer, (p_metrics->>'input_tokens')::integer,
     (p_metrics->>'output_tokens')::integer, (p_metrics->>'cost_usd')::numeric,
     md5(coalesce(p_response_text, '') || p_response_summary::text), p_metrics->>'error_code')
  ON CONFLICT (source_id, idempotency_key) DO UPDATE SET
    prompt_id = EXCLUDED.prompt_id,
    provider_model = EXCLUDED.provider_model,
    model_version = EXCLUDED.model_version,
    status = EXCLUDED.status,
    finished_at = EXCLUDED.finished_at,
    latency_ms = EXCLUDED.latency_ms,
    input_tokens = EXCLUDED.input_tokens,
    output_tokens = EXCLUDED.output_tokens,
    cost_usd = EXCLUDED.cost_usd,
    response_hash = EXCLUDED.response_hash,
    error_code = EXCLUDED.error_code,
    updated_at = now()
  RETURNING id INTO v_run_id;

  IF p_status = 'succeeded' THEN
    INSERT INTO market_intelligence.ai_responses
      (run_id, full_text, structured_summary, detected_language_code, retention_mode, expires_at)
    VALUES
      (v_run_id, p_response_text, p_response_summary, v_prompt.language_code, p_retention_mode,
       CASE WHEN p_retention_mode = 'full' THEN now() + make_interval(days => v_source.retention_days) ELSE NULL END)
    ON CONFLICT (run_id) DO UPDATE SET
      full_text = EXCLUDED.full_text,
      structured_summary = EXCLUDED.structured_summary,
      detected_language_code = EXCLUDED.detected_language_code,
      retention_mode = EXCLUDED.retention_mode,
      expires_at = EXCLUDED.expires_at;

    DELETE FROM market_intelligence.ai_mentions WHERE run_id = v_run_id;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_mentions)
    LOOP
      IF coalesce(length(v_item->>'brand_key'), 0) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'invalid_ai_mention';
      END IF;
      INSERT INTO market_intelligence.brands
        (brand_key, display_name, category, is_tippos, aliases, evidence_url)
      VALUES
        (market_intelligence.normalize_text(v_item->>'brand_key'),
         coalesce(nullif(v_item->>'display_name', ''), v_item->>'brand_key'),
         coalesce(nullif(v_item->>'category', ''), 'observed_competitor'),
         market_intelligence.normalize_text(v_item->>'brand_key') = 'tippos',
         ARRAY[coalesce(nullif(v_item->>'display_name', ''), v_item->>'brand_key')],
         v_item->>'evidence_url')
      ON CONFLICT (brand_key) DO UPDATE SET
        display_name = EXCLUDED.display_name,
        evidence_url = coalesce(EXCLUDED.evidence_url, market_intelligence.brands.evidence_url),
        updated_at = now()
      RETURNING id INTO v_brand_id;

      INSERT INTO market_intelligence.ai_mentions
        (run_id, brand_id, mention_position, sentiment, recommendation_strength, context_summary, confidence)
      VALUES
        (v_run_id, v_brand_id, (v_item->>'position')::integer, (v_item->>'sentiment')::numeric,
         (v_item->>'recommendation_strength')::numeric, v_item->>'context_summary',
         coalesce((v_item->>'confidence')::numeric, v_source.default_confidence));
    END LOOP;

    DELETE FROM market_intelligence.ai_citations WHERE run_id = v_run_id;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_citations)
    LOOP
      v_url := v_item->>'url';
      v_domain := lower(substring(v_url from '^https?://([^/:?#]+)'));
      IF v_domain IS NULL OR length(v_url) > 2048 THEN
        RAISE EXCEPTION 'invalid_ai_citation';
      END IF;
      INSERT INTO market_intelligence.domains (domain, display_name, is_tippos)
      VALUES (
        v_domain,
        v_domain,
        v_domain IN ('tippos.app', 'www.tippos.app', 'discover.tippos.app', 'app.tippos.app')
      )
      ON CONFLICT (domain) DO UPDATE SET updated_at = now()
      RETURNING id INTO v_domain_id;

      INSERT INTO market_intelligence.ai_citations
        (run_id, citation_order, url, canonical_url, domain_id, title, is_tippos)
      VALUES
        (v_run_id, (v_item->>'order')::integer, v_url, coalesce(nullif(v_item->>'canonical_url', ''), v_url),
         v_domain_id, v_item->>'title',
         v_domain IN ('tippos.app', 'www.tippos.app', 'discover.tippos.app', 'app.tippos.app'));
    END LOOP;

    IF v_source.status = 'disabled_pending_credentials' THEN
      UPDATE market_intelligence.sources
         SET status = 'enabled', last_success_at = now()
       WHERE id = v_source.id;
    ELSE
      UPDATE market_intelligence.sources SET last_success_at = now() WHERE id = v_source.id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'replayed', false, 'run_id', v_run_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.mi_cleanup_expired_data()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_raw integer;
  v_responses integer;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  DELETE FROM market_intelligence.raw_observations WHERE expires_at <= now();
  GET DIAGNOSTICS v_raw = ROW_COUNT;
  UPDATE market_intelligence.ai_responses
     SET full_text = NULL, retention_mode = 'summary', expires_at = NULL
   WHERE expires_at IS NOT NULL AND expires_at <= now() AND full_text IS NOT NULL;
  GET DIAGNOSTICS v_responses = ROW_COUNT;
  RETURN jsonb_build_object('raw_observations_deleted', v_raw, 'full_responses_reduced_to_summary', v_responses);
END;
$$;

CREATE OR REPLACE FUNCTION public.mi_get_active_prompts(p_prompt_keys text[] DEFAULT NULL)
RETURNS TABLE(prompt_key text, prompt_text text, language_code text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT p.prompt_key, p.prompt_text, p.language_code
      FROM market_intelligence.ai_prompts p
     WHERE p.active AND (p_prompt_keys IS NULL OR p.prompt_key = ANY(p_prompt_keys))
     ORDER BY p.prompt_key
     LIMIT 100;
END;
$$;

REVOKE ALL ON FUNCTION public.mi_record_ai_visibility(text,text,text,text,text,jsonb,text,text,jsonb,jsonb,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_record_ai_visibility(text,text,text,text,text,jsonb,text,text,jsonb,jsonb,jsonb)
  TO service_role;
REVOKE ALL ON FUNCTION public.mi_cleanup_expired_data() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_cleanup_expired_data() TO service_role;
REVOKE ALL ON FUNCTION public.mi_get_active_prompts(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_get_active_prompts(text[]) TO service_role;

-- Only production observations may influence market or language decisions.

CREATE OR REPLACE VIEW market_intelligence.v_keyword_opportunities
WITH (security_invoker = true)
AS
SELECT
  k.id AS keyword_id, k.original_text, k.language_code, k.intent, k.funnel_stage,
  k.business_relevance,
  coalesce(sum(sm.search_volume), 0) AS search_volume,
  coalesce(sum(sm.impressions), 0) AS impressions,
  coalesce(sum(sm.clicks), 0) AS clicks,
  round(avg(sm.trend_score), 2) AS average_trend,
  round(avg(sm.competition) * 100, 2) AS competition_percent,
  max(sm.observed_on) AS freshest_observation
FROM market_intelligence.keywords k
LEFT JOIN market_intelligence.search_metrics sm
  ON sm.keyword_id = k.id AND sm.data_nature <> 'synthetic'
GROUP BY k.id;

CREATE OR REPLACE VIEW market_intelligence.v_ai_visibility
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
JOIN market_intelligence.sources src ON src.id = r.source_id AND src.data_nature <> 'synthetic'
JOIN market_intelligence.ai_prompts p ON p.id = r.prompt_id
LEFT JOIN market_intelligence.ai_mentions m ON m.run_id = r.id
LEFT JOIN market_intelligence.brands b ON b.id = m.brand_id
GROUP BY p.language_code, r.provider_model, date_trunc('day', r.started_at)::date;

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
      coalesce(avg(1 - sm.competition), 0) * 100 AS competition_opportunity,
      count(DISTINCT sm.observed_on) AS observed_days,
      avg(sm.confidence) AS source_confidence
    FROM market_intelligence.keywords k
    LEFT JOIN market_intelligence.search_metrics sm
      ON sm.keyword_id = k.id
     AND sm.observed_on BETWEEN p_period_start AND p_period_end
     AND sm.data_nature <> 'synthetic'
    GROUP BY k.language_code
  ), ai_rollup AS (
    SELECT p.language_code,
      100.0 * count(DISTINCT r.id) FILTER (WHERE b.is_tippos AND src.data_nature <> 'synthetic')
        / nullif(count(DISTINCT r.id) FILTER (WHERE r.status = 'succeeded' AND src.data_nature <> 'synthetic'), 0) AS visibility,
      count(DISTINCT r.id) FILTER (WHERE r.status = 'succeeded' AND src.data_nature <> 'synthetic') AS ai_runs
    FROM market_intelligence.ai_prompts p
    LEFT JOIN market_intelligence.ai_runs r ON r.prompt_id = p.id
      AND r.started_at::date BETWEEN p_period_start AND p_period_end
    LEFT JOIN market_intelligence.sources src ON src.id = r.source_id
    LEFT JOIN market_intelligence.ai_mentions m ON m.run_id = r.id
    LEFT JOIN market_intelligence.brands b ON b.id = m.brand_id
    GROUP BY p.language_code
  ), scored AS (
    SELECT l.code,
      least(100, round((ln(1 + coalesce(s.demand, 0)) * 8)::numeric, 2)) AS demand_score,
      CASE WHEN s.trend IS NULL THEN 0 ELSE least(100, greatest(0, round((50 + s.trend / 2)::numeric, 2))) END AS growth_score,
      least(100, greatest(0, round(coalesce(s.relevance, 0)::numeric, 2))) AS relevance_score,
      least(100, greatest(0, round(coalesce(a.visibility, 0)::numeric, 2))) AS visibility_score,
      least(100, greatest(0, round(coalesce(s.competition_opportunity, 0)::numeric, 2))) AS competition_score,
      least(100, round((100.0 * least(coalesce(s.observed_days, 0), 30) / 30)::numeric, 2)) AS coverage_score,
      CASE WHEN l.product_status = 'supported' THEN 100
           WHEN l.estimated_localization_cost IS NULL THEN 0
           ELSE greatest(0, least(100, round((100 - l.estimated_localization_cost / 100)::numeric, 2))) END AS effort_score,
      coalesce(s.source_confidence, 0) AS confidence,
      coalesce(a.ai_runs, 0) AS ai_runs,
      coalesce(s.observed_days, 0) AS observed_days
    FROM market_intelligence.languages l
    LEFT JOIN search_rollup s ON s.language_code = l.code
    LEFT JOIN ai_rollup a ON a.language_code = l.code
    WHERE l.code <> 'und'
      AND (coalesce(s.observed_days, 0) > 0 OR coalesce(a.ai_runs, 0) > 0)
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
      'synthetic_data_excluded', true,
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

REVOKE EXECUTE ON FUNCTION public.mi_refresh_language_scores(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_refresh_language_scores(date, date) TO service_role;
