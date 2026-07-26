-- Narrow service-role read boundary for qualitative Google Autocomplete signals.

WITH suggestions(original_text, use_case, industry, relevance) AS (
  VALUES
    ('how much should i tip at the nail salon', 'nail-services', 'personal-services', 90::numeric),
    ('how much should i tip a tattoo artist', 'tattoo-services', 'personal-services', 82::numeric),
    ('how much should i tip an uber driver', 'rideshare', 'transport', 90::numeric),
    ('how much should i tip a valet at a hotel', 'hotel-valet', 'hospitality', 95::numeric),
    ('how much should i tip at a restaurant', 'restaurant-service', 'restaurants', 92::numeric)
)
INSERT INTO market_intelligence.keywords (
  original_text,
  normalized_text,
  language_code,
  country_code,
  intent,
  funnel_stage,
  persona,
  industry,
  use_case,
  is_branded,
  business_relevance
)
SELECT
  original_text,
  market_intelligence.normalize_text(original_text),
  'en',
  NULL,
  'informational'::market_intelligence.search_intent,
  'awareness',
  'tip_giver',
  industry,
  use_case,
  original_text LIKE '% uber %',
  relevance
FROM suggestions
ON CONFLICT (normalized_text, language_code, (coalesce(country_code, '*'))) DO UPDATE SET
  intent = EXCLUDED.intent,
  funnel_stage = EXCLUDED.funnel_stage,
  persona = EXCLUDED.persona,
  industry = EXCLUDED.industry,
  use_case = EXCLUDED.use_case,
  is_branded = EXCLUDED.is_branded,
  business_relevance = EXCLUDED.business_relevance,
  active = true,
  updated_at = now();

WITH mappings(keyword_text, topic_slug, relevance) AS (
  VALUES
    ('how much should i tip at the nail salon', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip at the nail salon', 'wellness', 0.900::numeric),
    ('how much should i tip a tattoo artist', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip a tattoo artist', 'wellness', 0.750::numeric),
    ('how much should i tip an uber driver', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip an uber driver', 'transport', 1.000::numeric),
    ('how much should i tip a valet at a hotel', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip a valet at a hotel', 'hospitality', 1.000::numeric),
    ('how much should i tip a valet at a hotel', 'transport', 0.900::numeric),
    ('how much should i tip at a restaurant', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip at a restaurant', 'restaurants', 1.000::numeric)
)
INSERT INTO market_intelligence.keyword_topics (keyword_id, topic_id, relevance)
SELECT k.id, t.id, m.relevance
FROM mappings m
JOIN market_intelligence.keywords k
  ON k.normalized_text = market_intelligence.normalize_text(m.keyword_text)
 AND k.language_code = 'en'
 AND k.country_code IS NULL
JOIN market_intelligence.topics t ON t.slug = m.topic_slug
ON CONFLICT (keyword_id, topic_id) DO UPDATE SET relevance = EXCLUDED.relevance;

WITH source AS (
  SELECT id FROM market_intelligence.sources WHERE source_key = 'google_autocomplete_manual'
), observation AS (
  SELECT jsonb_build_object(
    'provider', 'Google Autocomplete',
    'observed_on', '2026-07-23',
    'typed_prefix', 'how much should i tip a',
    'locale', 'English UI',
    'country_code', NULL,
    'device', 'mobile',
    'suggestions', jsonb_build_array(
      'how much should i tip at the nail salon',
      'how much should i tip a tattoo artist',
      'how much should i tip an uber driver',
      'how much should i tip a valet at a hotel',
      'how much should i tip at a restaurant'
    ),
    'interpretation', 'Autocomplete presence indicates query relevance, not search volume or rank.',
    'evidence', 'Founder-supplied mobile screenshot reviewed manually.'
  ) AS payload
)
INSERT INTO market_intelligence.raw_observations (
  source_id,
  external_id,
  observation_type,
  event_at,
  data_nature,
  confidence,
  checksum,
  payload,
  expires_at
)
SELECT
  source.id,
  'founder-screenshot-2026-07-23-how-much-should-i-tip-a',
  'autocomplete_suggestions',
  '2026-07-23T02:07:00Z'::timestamptz,
  'third_party'::market_intelligence.data_nature,
  0.800,
  md5(observation.payload::text),
  observation.payload,
  now() + interval '730 days'
FROM source CROSS JOIN observation
ON CONFLICT (source_id, observation_type, checksum) DO UPDATE SET
  external_id = EXCLUDED.external_id,
  event_at = EXCLUDED.event_at,
  confidence = EXCLUDED.confidence,
  payload = EXCLUDED.payload,
  expires_at = EXCLUDED.expires_at;

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
  )
  SELECT DISTINCT ON (k.normalized_text)
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
  ORDER BY k.normalized_text, o.observed_on DESC
  LIMIT 100;
$$;

REVOKE ALL ON FUNCTION public.mi_get_autocomplete_search_signals() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_get_autocomplete_search_signals() TO service_role;
