CREATE OR REPLACE FUNCTION public.mi_get_us_strategy_evidence()
RETURNS TABLE (
  evidence_key text,
  category text,
  metric_key text,
  metric_value numeric,
  metric_unit text,
  period_start date,
  period_end date,
  claim_summary text,
  strategic_relevance text,
  publisher text,
  source_title text,
  source_url text,
  published_on date,
  confidence numeric
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = market_intelligence, public
AS $$
  SELECT
    evidence_key,
    category,
    metric_key,
    metric_value,
    metric_unit,
    period_start,
    period_end,
    claim_summary,
    strategic_relevance,
    publisher,
    source_title,
    source_url,
    published_on,
    confidence
  FROM market_intelligence.market_evidence
  WHERE country_code = 'US'
  ORDER BY confidence DESC, evidence_key ASC
  LIMIT 30;
$$;

REVOKE ALL ON FUNCTION public.mi_get_us_strategy_evidence() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_get_us_strategy_evidence() TO service_role;
