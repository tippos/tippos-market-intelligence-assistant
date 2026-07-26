-- Synthetic fixtures verify pipelines but must never influence market or
-- language decisions.

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
      coalesce(avg(1 - sm.competition), 0.5) * 100 AS competition_opportunity,
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
