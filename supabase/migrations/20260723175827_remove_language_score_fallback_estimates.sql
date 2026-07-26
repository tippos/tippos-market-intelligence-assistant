-- Normalize missing score inputs to zero instead of fabricating neutral values.
CREATE OR REPLACE FUNCTION market_intelligence.reject_unobserved_language_score()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
DECLARE
  v_has_search_observations boolean;
  v_has_trend_observations boolean;
  v_has_competition_observations boolean;
  v_has_localization_cost boolean;
  v_is_supported boolean;
BEGIN
  IF coalesce((NEW.rationale ->> 'observed_days')::integer, 0) = 0
     AND coalesce((NEW.rationale ->> 'ai_runs')::integer, 0) = 0 THEN
    RETURN NULL;
  END IF;

  SELECT bool_or(true), bool_or(sm.trend_score IS NOT NULL), bool_or(sm.competition IS NOT NULL)
    INTO v_has_search_observations, v_has_trend_observations, v_has_competition_observations
  FROM market_intelligence.search_metrics sm
  JOIN market_intelligence.keywords k ON k.id = sm.keyword_id
  WHERE k.language_code = NEW.language_code
    AND sm.observed_on BETWEEN NEW.period_start AND NEW.period_end
    AND sm.data_nature <> 'synthetic';

  SELECT estimated_localization_cost IS NOT NULL, product_status = 'supported'
    INTO v_has_localization_cost, v_is_supported
  FROM market_intelligence.languages
  WHERE code = NEW.language_code;

  IF NOT coalesce(v_has_trend_observations, false) THEN NEW.growth_score := 0; END IF;
  IF NOT coalesce(v_has_competition_observations, false) THEN NEW.competition_opportunity_score := 0; END IF;
  IF NOT coalesce(v_has_localization_cost, false) AND NOT coalesce(v_is_supported, false) THEN NEW.localization_effort_score := 0; END IF;
  IF NOT coalesce(v_has_search_observations, false) THEN NEW.confidence := 0; END IF;

  NEW.total_opportunity_score := round((
    NEW.demand_score * 0.30 + NEW.growth_score * 0.15
    + NEW.business_relevance_score * 0.20
    + (100 - NEW.ai_visibility_score) * 0.10
    + NEW.competition_opportunity_score * 0.10
    + NEW.data_coverage_score * 0.10
    + NEW.localization_effort_score * 0.05
  )::numeric, 2);
  RETURN NEW;
END;
$$;
