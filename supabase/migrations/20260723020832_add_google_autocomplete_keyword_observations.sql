-- Manually reviewed Google Autocomplete suggestions supplied by the founder.
-- Autocomplete presence is a qualitative demand signal only; it is not search volume.

INSERT INTO market_intelligence.sources (
  source_key,
  display_name,
  kind,
  status,
  base_url,
  terms_url,
  collection_method,
  data_nature,
  default_confidence,
  retention_days,
  config_schema
) VALUES (
  'google_autocomplete_manual',
  'Google Autocomplete (manual observations)',
  'keyword_provider',
  'enabled',
  'https://www.google.com/',
  'https://policies.google.com/terms',
  'manual',
  'third_party',
  0.800,
  730,
  '{"metric_interpretation":"qualitative_query_signal_only","search_volume_available":false,"geography_must_not_be_inferred":true}'::jsonb
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

WITH suggestions(original_text, use_case, industry, relevance) AS (
  VALUES
    ('how much should i tip movers', 'moving-services', 'home-services', 88::numeric),
    ('how much should i tip my tattoo artist', 'tattoo-services', 'personal-services', 82::numeric),
    ('how much should i tip my hairdresser', 'hair-services', 'personal-services', 88::numeric),
    ('how much should i tip easy rider ha giang loop', 'motorcycle-tour-guides', 'travel-and-tours', 65::numeric),
    ('how much should i tip uber', 'rideshare', 'transport', 90::numeric)
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
  original_text LIKE '% uber',
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
    ('how much should i tip movers', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip my tattoo artist', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip my tattoo artist', 'wellness', 0.750::numeric),
    ('how much should i tip my hairdresser', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip my hairdresser', 'wellness', 0.850::numeric),
    ('how much should i tip easy rider ha giang loop', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip easy rider ha giang loop', 'transport', 0.700::numeric),
    ('how much should i tip uber', 'tipping-etiquette', 1.000::numeric),
    ('how much should i tip uber', 'transport', 1.000::numeric)
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
    'typed_prefix', 'how much should i ti',
    'locale', 'English UI',
    'country_code', NULL,
    'device', 'mobile',
    'suggestions', jsonb_build_array(
      'how much should i tip movers',
      'how much should i tip my tattoo artist',
      'how much should i tip my hairdresser',
      'how much should i tip easy rider ha giang loop',
      'how much should i tip uber'
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
  'founder-screenshot-2026-07-23-how-much-should-i-tip',
  'autocomplete_suggestions',
  '2026-07-23T02:05:00Z'::timestamptz,
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
