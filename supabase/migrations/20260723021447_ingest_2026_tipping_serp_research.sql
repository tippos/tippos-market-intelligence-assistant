-- Founder-supplied mobile SERP capture for "how much should I tip in 2026",
-- enriched with verified primary/first-party research. Screenshot rankings are
-- context-specific observations, not universal Google positions.

INSERT INTO market_intelligence.sources (
  source_key, display_name, kind, status, base_url, terms_url,
  collection_method, data_nature, default_confidence, retention_days, config_schema
) VALUES (
  'google_serp_manual',
  'Google SERP (manual observations)',
  'keyword_provider',
  'enabled',
  'https://www.google.com/',
  'https://policies.google.com/terms',
  'manual',
  'third_party',
  0.850,
  730,
  '{"metric_interpretation":"query-device-time-specific_serp_snapshot","rank_is_universal":false,"geography_must_not_be_inferred":true}'::jsonb
)
ON CONFLICT (source_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  status = EXCLUDED.status,
  base_url = EXCLUDED.base_url,
  terms_url = EXCLUDED.terms_url,
  collection_method = EXCLUDED.collection_method,
  data_nature = EXCLUDED.data_nature,
  default_confidence = EXCLUDED.default_confidence,
  retention_days = EXCLUDED.retention_days,
  config_schema = EXCLUDED.config_schema,
  updated_at = now();

INSERT INTO market_intelligence.keywords (
  original_text, normalized_text, language_code, country_code, intent,
  funnel_stage, persona, industry, use_case, is_branded, business_relevance
) VALUES (
  'how much should i tip in 2026',
  market_intelligence.normalize_text('how much should i tip in 2026'),
  'en', NULL, 'informational', 'awareness', 'tip_giver', 'multi-service',
  'current-year-tipping-guide', false, 100
)
ON CONFLICT (normalized_text, language_code, (coalesce(country_code, '*'))) DO UPDATE SET
  intent = EXCLUDED.intent,
  funnel_stage = EXCLUDED.funnel_stage,
  persona = EXCLUDED.persona,
  industry = EXCLUDED.industry,
  use_case = EXCLUDED.use_case,
  business_relevance = EXCLUDED.business_relevance,
  active = true,
  updated_at = now();

WITH keyword AS (
  SELECT id FROM market_intelligence.keywords
  WHERE normalized_text = market_intelligence.normalize_text('how much should i tip in 2026')
    AND language_code = 'en' AND country_code IS NULL
), variants(variant_text, variant_type) AS (
  VALUES
    ('how much to tip in 2026', 'related'),
    ('2026 tipping chart', 'related'),
    ('US tipping chart 2026', 'related'),
    ('travel tipping guide 2026', 'related')
)
INSERT INTO market_intelligence.keyword_variants (
  keyword_id, variant_text, normalized_text, variant_type, language_code
)
SELECT keyword.id, variants.variant_text,
  market_intelligence.normalize_text(variants.variant_text),
  variants.variant_type, 'en'
FROM keyword CROSS JOIN variants
ON CONFLICT (keyword_id, normalized_text, language_code) DO UPDATE SET
  variant_text = EXCLUDED.variant_text,
  variant_type = EXCLUDED.variant_type;

INSERT INTO market_intelligence.keyword_topics (keyword_id, topic_id, relevance)
SELECT k.id, t.id, 1.000
FROM market_intelligence.keywords k
JOIN market_intelligence.topics t ON t.slug = 'tipping-etiquette'
WHERE k.normalized_text = market_intelligence.normalize_text('how much should i tip in 2026')
  AND k.language_code = 'en' AND k.country_code IS NULL
ON CONFLICT (keyword_id, topic_id) DO UPDATE SET relevance = EXCLUDED.relevance;

INSERT INTO market_intelligence.domains (domain, display_name, owner_brand, category, is_tippos)
VALUES
  ('google.com', 'Google', 'Google', 'search-engine', false),
  ('splittyapp.com', 'Splitty', 'Splitty', 'product-content-competitor', false),
  ('remitly.com', 'Remitly', 'Remitly', 'finance-publisher', false),
  ('withautopilot.com', 'Autopilot Travel', 'Autopilot', 'travel-publisher', false)
ON CONFLICT (domain) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  owner_brand = EXCLUDED.owner_brand,
  category = EXCLUDED.category,
  updated_at = now();

INSERT INTO market_intelligence.brands (brand_key, display_name, category, is_tippos, aliases, evidence_url)
VALUES
  ('splitty', 'Splitty', 'product-content-competitor', false, ARRAY['splitty', 'splitty app'], 'https://splittyapp.com/learn/tipping-chart-2026/'),
  ('remitly', 'Remitly', 'finance-publisher', false, ARRAY['Remitly'], 'https://www.remitly.com/blog/finance/tip-chart/'),
  ('autopilot-travel', 'Autopilot Travel', 'travel-publisher', false, ARRAY['Autopilot', 'withAutopilot.com'], 'https://withautopilot.com/blog/travel-tipping-guide')
ON CONFLICT (brand_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  category = EXCLUDED.category,
  aliases = EXCLUDED.aliases,
  evidence_url = EXCLUDED.evidence_url,
  updated_at = now();

WITH keyword AS (
  SELECT id FROM market_intelligence.keywords
  WHERE normalized_text = market_intelligence.normalize_text('how much should i tip in 2026')
    AND language_code = 'en' AND country_code IS NULL
), source AS (
  SELECT id FROM market_intelligence.sources WHERE source_key = 'google_serp_manual'
)
INSERT INTO market_intelligence.search_results_snapshots (
  keyword_id, source_id, captured_at, country_code, device, result_count
)
SELECT keyword.id, source.id, '2026-07-23T02:09:00Z'::timestamptz, NULL, 'mobile', NULL
FROM keyword CROSS JOIN source
WHERE NOT EXISTS (
  SELECT 1 FROM market_intelligence.search_results_snapshots existing
  WHERE existing.keyword_id = keyword.id
    AND existing.source_id = source.id
    AND existing.captured_at = '2026-07-23T02:09:00Z'::timestamptz
    AND existing.country_code IS NULL
    AND existing.device = 'mobile'
);

WITH snapshot AS (
  SELECT srs.id
  FROM market_intelligence.search_results_snapshots srs
  JOIN market_intelligence.keywords k ON k.id = srs.keyword_id
  JOIN market_intelligence.sources s ON s.id = srs.source_id
  WHERE k.normalized_text = market_intelligence.normalize_text('how much should i tip in 2026')
    AND s.source_key = 'google_serp_manual'
    AND srs.captured_at = '2026-07-23T02:09:00Z'::timestamptz
    AND srs.country_code IS NULL
    AND srs.device = 'mobile'
  ORDER BY srs.created_at DESC
  LIMIT 1
), items(rank, result_type, url, canonical_url, domain, title, snippet) AS (
  VALUES
    (1, 'ai_overview', 'https://www.google.com/search?q=how+much+should+i+tip+in+2026', 'https://www.google.com/search?q=how+much+should+i+tip+in+2026', 'google.com', 'AI Overview: how much should I tip in 2026', 'Visible answer: full-service restaurants 18%-20% pre-tax; spas and hair salons 20%; fast-casual and counter service optional at 10%-15% or $1 per item. Additional visible guidance mentioned service-quality and group-size adjustments.'),
    (1, 'organic', 'https://splittyapp.com/learn/tipping-chart-2026/', 'https://splittyapp.com/learn/tipping-chart-2026/', 'splittyapp.com', '2026 tipping chart: how much to tip (save this)', 'Full-service 20%; fast-casual 15%; counter 10%; delivery 18%; bars $1-$2 per drink. The result also displayed an iOS app rating and deep-link chips.'),
    (2, 'organic', 'https://www.remitly.com/blog/finance/tip-chart/', 'https://www.remitly.com/blog/finance/tip-chart/', 'remitly.com', 'The Ultimate US Tipping Chart for 2026', 'A US tipping chart positioned around uncertainty for newcomers, including sit-down restaurants, bartenders and other services.'),
    (3, 'organic', 'https://withautopilot.com/blog/travel-tipping-guide', 'https://withautopilot.com/blog/travel-tipping-guide', 'withautopilot.com', 'The Complete Travel Tipping Guide for 2026: How Much to Tip in 30+ Countries', 'Travel-oriented country guide; the visible snippet described an 18%-20% adequate-service baseline and 22%-25% for great service in the US.')
)
INSERT INTO market_intelligence.search_result_items (
  snapshot_id, rank, url, canonical_url, domain_id, title, snippet, result_type, is_tippos
)
SELECT snapshot.id, items.rank, items.url, items.canonical_url, domains.id,
  items.title, items.snippet, items.result_type, false
FROM snapshot CROSS JOIN items
JOIN market_intelligence.domains domains ON domains.domain = items.domain
ON CONFLICT (snapshot_id, rank, result_type) DO UPDATE SET
  url = EXCLUDED.url,
  canonical_url = EXCLUDED.canonical_url,
  domain_id = EXCLUDED.domain_id,
  title = EXCLUDED.title,
  snippet = EXCLUDED.snippet,
  is_tippos = EXCLUDED.is_tippos;

WITH source AS (
  SELECT id FROM market_intelligence.sources WHERE source_key = 'google_serp_manual'
), observation AS (
  SELECT jsonb_build_object(
    'provider', 'Google Search',
    'query', 'how much should i tip in 2026',
    'captured_at', '2026-07-23T02:09:00Z',
    'device', 'mobile',
    'country_code', NULL,
    'features', jsonb_build_array('ai_overview', 'organic_results', 'app_rich_result', 'deep_link_chips'),
    'ai_overview_visible_claims', jsonb_build_array(
      jsonb_build_object('claim', 'Full-service restaurants: 18%-20% of the pre-tax bill; 20% widely standard.', 'confidence', 0.80, 'validation', 'Consistent with Toast Q1 2026 observed average of 19.3% for tipped card and digital transactions.'),
      jsonb_build_object('claim', 'Spas and hair salons: 20% customary.', 'confidence', 0.60, 'validation', 'Editorial norm visible in the screenshot; no equivalent primary transaction dataset was identified in this pass.'),
      jsonb_build_object('claim', 'Fast-casual and counter service: optional, typically 10%-15% or $1 per item.', 'confidence', 0.65, 'validation', 'Toast reports 15.8% at quick-service restaurants among tipped card/digital transactions, which does not establish optionality or a 10% floor.'),
      jsonb_build_object('claim', 'Sit-down service can range from 10%-15% for poor service to 25% for exceptional service.', 'confidence', 0.55, 'validation', 'Normative editorial guidance, not a measured distribution in the verified sources.'),
      jsonb_build_object('claim', 'Groups of six or more frequently receive 18%-20% automatic gratuity.', 'confidence', 0.50, 'validation', 'Venue policy varies; screenshot observation retained without treating it as a universal rule.')
    ),
    'visible_organic_results', jsonb_build_array(
      jsonb_build_object('rank', 1, 'domain', 'splittyapp.com', 'angle', 'current-year chart plus app/calculator product'),
      jsonb_build_object('rank', 2, 'domain', 'remitly.com', 'angle', 'US finance and newcomer education'),
      jsonb_build_object('rank', 3, 'domain', 'withautopilot.com', 'angle', 'international travel guide by country')
    ),
    'interpretation', 'A mobile SERP showed an AI Overview followed by Splitty, Remitly and Autopilot Travel; Tippos was not visible. Rankings are specific to this capture. The opportunity is a sourced, current-year interactive tipping guide connected directly to the act of giving a tip.'
  ) AS payload
)
INSERT INTO market_intelligence.raw_observations (
  source_id, external_id, observation_type, event_at, data_nature,
  confidence, checksum, payload, expires_at
)
SELECT source.id, 'founder-screenshots-2026-07-23-how-much-tip-2026',
  'manual_serp_snapshot', '2026-07-23T02:09:00Z'::timestamptz,
  'third_party'::market_intelligence.data_nature, 0.850,
  md5(observation.payload::text), observation.payload, now() + interval '730 days'
FROM source CROSS JOIN observation
ON CONFLICT (source_id, observation_type, checksum) DO UPDATE SET
  external_id = EXCLUDED.external_id,
  event_at = EXCLUDED.event_at,
  confidence = EXCLUDED.confidence,
  payload = EXCLUDED.payload,
  expires_at = EXCLUDED.expires_at;

WITH source AS (
  SELECT id FROM market_intelligence.sources WHERE source_key = 'codex_public_research'
), evidence(
  evidence_key, category, metric_key, metric_value, metric_unit,
  period_start, period_end, claim_summary, strategic_relevance,
  publisher, source_title, source_url, published_on, confidence,
  methodology_notes, metadata
) AS (
  VALUES
    ('us-toast-fsr-tip-rate-q1-2026', 'consumer_behavior', 'full_service_restaurant_average_tip_rate', 19.3::numeric, 'percent', '2026-01-01'::date, '2026-03-31'::date, 'Toast reported a 19.3% average tip at US full-service restaurants in Q1 2026.', 'Supports an 18%-20% consumer guideline while giving Tippos a measured benchmark for restaurant-related content.', 'Toast', 'Restaurant Tipping Trends', 'https://pos.toasttab.com/th-us/blog/data/restaurant-tipping-trends', '2026-06-24'::date, 0.950::numeric, 'Aggregated card and digital tip transactions from roughly 171,000 Toast locations as of March 31, 2026; cash tips are excluded.', '{"segment":"full_service_restaurants","cash_tips_included":false}'::jsonb),
    ('us-toast-qsr-tip-rate-q1-2026', 'consumer_behavior', 'quick_service_restaurant_average_tip_rate', 15.8::numeric, 'percent', '2026-01-01'::date, '2026-03-31'::date, 'Toast reported a 15.8% average tip at US quick-service restaurants in Q1 2026.', 'Quantifies the gap between full-service and quick-service tipping and supports separate guidance by service model.', 'Toast', 'Restaurant Tipping Trends', 'https://pos.toasttab.com/th-us/blog/data/restaurant-tipping-trends', '2026-06-24'::date, 0.950::numeric, 'Aggregated card and digital tip transactions from Toast restaurants; the metric describes transactions that included a tip and does not measure how often consumers chose no tip.', '{"segment":"quick_service_restaurants","cash_tips_included":false}'::jsonb),
    ('us-toast-overall-tip-rate-q1-2026', 'consumer_behavior', 'restaurant_overall_average_tip_rate', 18.8::numeric, 'percent', '2026-01-01'::date, '2026-03-31'::date, 'Toast reported an 18.8% overall average tip across US restaurant types in Q1 2026.', 'Provides a current behavioral reference point for the broad 2026 tipping-guide query.', 'Toast', 'Restaurant Tipping Trends', 'https://pos.toasttab.com/th-us/blog/data/restaurant-tipping-trends', '2026-06-24'::date, 0.950::numeric, 'Overall tips are total tips divided by gross processing volume in the Toast dataset; cash tips are excluded.', '{"segment":"all_restaurants","cash_tips_included":false}'::jsonb),
    ('us-toast-takeout-tip-rate-q1-2026', 'consumer_behavior', 'takeout_average_tip_rate', 13.7::numeric, 'percent', '2026-01-01'::date, '2026-03-31'::date, 'Toast reported that tipped US takeout transactions averaged 13.7% in Q1 2026.', 'Shows why a useful product should distinguish takeout from table service instead of presenting one restaurant percentage.', 'Toast', 'Restaurant Tipping Trends', 'https://pos.toasttab.com/th-us/blog/data/restaurant-tipping-trends', '2026-06-24'::date, 0.920::numeric, 'The figure covers takeout transactions where a tip was left; it does not measure the share of takeout orders receiving no tip.', '{"segment":"takeout","cash_tips_included":false}'::jsonb),
    ('us-bankrate-negative-tipping-views-2025', 'consumer_behavior', 'adults_with_negative_tipping_view', 63::numeric, 'percent', '2025-04-23'::date, '2025-04-25'::date, 'Bankrate reported that 63% of US adults held at least one negative view about tipping in its 2025 survey.', 'Reinforces the need for neutral, non-coercive guidance and a product experience that avoids tip-pressure patterns.', 'Bankrate', '63% of Americans Have a Negative View About Tipping', 'https://www.bankrate.com/press-releases/63-of-americans-have-a-negative-view-about-tipping-with-41-saying-tipping-culture-has-gotten-out-of-control/', '2025-06-04'::date, 0.900::numeric, 'Online YouGov panel survey of 2,277 US adults using demographic quotas and weights; non-probability sample.', '{"sample_size":2277,"survey_provider":"YouGov"}'::jsonb),
    ('us-bankrate-tipping-out-of-control-2025', 'consumer_behavior', 'adults_saying_tipping_out_of_control', 41::numeric, 'percent', '2025-04-23'::date, '2025-04-25'::date, 'Bankrate reported that 41% of US adults said tipping culture had gotten out of control in 2025.', 'Suggests Tippos should frame guidance as clarity and choice rather than encouraging tip inflation.', 'Bankrate', '63% of Americans Have a Negative View About Tipping', 'https://www.bankrate.com/press-releases/63-of-americans-have-a-negative-view-about-tipping-with-41-saying-tipping-culture-has-gotten-out-of-control/', '2025-06-04'::date, 0.900::numeric, 'Online YouGov panel survey of 2,277 US adults using demographic quotas and weights; non-probability sample.', '{"sample_size":2277,"survey_provider":"YouGov"}'::jsonb),
    ('us-bankrate-annoyed-tip-screens-2025', 'consumer_behavior', 'adults_annoyed_by_preentered_tip_screens', 38::numeric, 'percent', '2025-04-23'::date, '2025-04-25'::date, 'Bankrate reported that 38% of US adults were annoyed by pre-entered tip screens in 2025.', 'Supports a calm interface with an editable amount and no manipulative preselected percentage.', 'Bankrate', '63% of Americans Have a Negative View About Tipping', 'https://www.bankrate.com/press-releases/63-of-americans-have-a-negative-view-about-tipping-with-41-saying-tipping-culture-has-gotten-out-of-control/', '2025-06-04'::date, 0.900::numeric, 'Online YouGov panel survey of 2,277 US adults using demographic quotas and weights; non-probability sample.', '{"sample_size":2277,"survey_provider":"YouGov"}'::jsonb),
    ('us-restaurant-tip-trend-lynn-2025', 'consumer_behavior', 'restaurant_tip_rate_trend_per_year', 0.16::numeric, 'percentage_points_per_year', NULL::date, NULL::date, 'A 2025 research note found a statistically significant long-run increase in US restaurant tip percentages of about 0.16 percentage points per year.', 'Supports annual freshness in tipping guidance but does not justify inventing a universal 2026 norm for every service category.', 'International Journal of Hospitality Management', 'How have U.S. restaurant tips changed over time?', 'https://www.sciencedirect.com/science/article/abs/pii/S0278431924002810', '2025-01-01'::date, 0.930::numeric, 'The paper assembled 64 observations from academic studies of real US restaurant tipping situations; OLS coefficient B=.16, SE=.03, p<.001, R-squared=.345.', '{"doi":"10.1016/j.ijhm.2024.103969","observations":64}'::jsonb)
)
INSERT INTO market_intelligence.market_evidence (
  evidence_key, source_id, country_code, language_code, category,
  metric_key, metric_value, metric_unit, period_start, period_end,
  claim_summary, strategic_relevance, publisher, source_title, source_url,
  published_on, data_nature, confidence, methodology_notes, metadata
)
SELECT evidence.evidence_key, source.id, 'US', 'en', evidence.category,
  evidence.metric_key, evidence.metric_value, evidence.metric_unit,
  evidence.period_start, evidence.period_end, evidence.claim_summary,
  evidence.strategic_relevance, evidence.publisher, evidence.source_title,
  evidence.source_url, evidence.published_on,
  'third_party'::market_intelligence.data_nature, evidence.confidence,
  evidence.methodology_notes, evidence.metadata
FROM source CROSS JOIN evidence
ON CONFLICT (evidence_key) DO UPDATE SET
  category = EXCLUDED.category,
  metric_key = EXCLUDED.metric_key,
  metric_value = EXCLUDED.metric_value,
  metric_unit = EXCLUDED.metric_unit,
  period_start = EXCLUDED.period_start,
  period_end = EXCLUDED.period_end,
  claim_summary = EXCLUDED.claim_summary,
  strategic_relevance = EXCLUDED.strategic_relevance,
  publisher = EXCLUDED.publisher,
  source_title = EXCLUDED.source_title,
  source_url = EXCLUDED.source_url,
  published_on = EXCLUDED.published_on,
  confidence = EXCLUDED.confidence,
  methodology_notes = EXCLUDED.methodology_notes,
  metadata = EXCLUDED.metadata,
  retrieved_at = now(),
  updated_at = now();

-- Include both autocomplete and manually observed SERP queries in the private assistant.
CREATE OR REPLACE FUNCTION public.mi_get_autocomplete_search_signals()
RETURNS TABLE (
  query_text text,
  use_case text,
  industry text,
  business_relevance numeric,
  observed_on date,
  country_code text,
  source_key text,
  confidence numeric,
  interpretation text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = market_intelligence, public
AS $$
  WITH observations AS (
    SELECT
      s.source_key,
      ro.event_at::date AS observed_on,
      ro.confidence,
      ro.payload ->> 'country_code' AS country_code,
      ro.payload ->> 'interpretation' AS interpretation,
      suggestion.query_text
    FROM market_intelligence.raw_observations ro
    JOIN market_intelligence.sources s ON s.id = ro.source_id
    CROSS JOIN LATERAL jsonb_array_elements_text(ro.payload -> 'suggestions') AS suggestion(query_text)
    WHERE s.source_key = 'google_autocomplete_manual'
      AND ro.observation_type = 'autocomplete_suggestions'
      AND ro.expires_at > now()

    UNION ALL

    SELECT
      s.source_key,
      ro.event_at::date,
      ro.confidence,
      ro.payload ->> 'country_code',
      ro.payload ->> 'interpretation',
      ro.payload ->> 'query'
    FROM market_intelligence.raw_observations ro
    JOIN market_intelligence.sources s ON s.id = ro.source_id
    WHERE s.source_key = 'google_serp_manual'
      AND ro.observation_type = 'manual_serp_snapshot'
      AND ro.expires_at > now()
  )
  SELECT DISTINCT ON (k.normalized_text, o.source_key)
    k.original_text AS query_text,
    k.use_case,
    k.industry,
    k.business_relevance,
    o.observed_on,
    nullif(o.country_code, '') AS country_code,
    o.source_key,
    o.confidence,
    o.interpretation
  FROM observations o
  JOIN market_intelligence.keywords k
    ON k.normalized_text = market_intelligence.normalize_text(o.query_text)
   AND k.language_code = 'en'
  WHERE k.active
  ORDER BY k.normalized_text, o.source_key, o.observed_on DESC
  LIMIT 100;
$$;

REVOKE ALL ON FUNCTION public.mi_get_autocomplete_search_signals() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_get_autocomplete_search_signals() TO service_role;
