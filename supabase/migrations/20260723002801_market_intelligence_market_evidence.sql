-- Structured, cited market evidence collected from authoritative public sources.

CREATE TABLE market_intelligence.market_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_key text NOT NULL UNIQUE CHECK (evidence_key ~ '^[a-z0-9][a-z0-9_-]{2,199}$'),
  source_id uuid NOT NULL REFERENCES market_intelligence.sources(id) ON DELETE RESTRICT,
  country_code text NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
  language_code text NOT NULL REFERENCES market_intelligence.languages(code) ON DELETE RESTRICT,
  category text NOT NULL CHECK (category IN (
    'payment_adoption',
    'cash_reliance',
    'tipping_regulation',
    'service_market',
    'consumer_behavior'
  )),
  metric_key text,
  metric_value numeric,
  metric_unit text,
  period_start date,
  period_end date,
  claim_summary text NOT NULL CHECK (length(claim_summary) BETWEEN 20 AND 2000),
  strategic_relevance text NOT NULL CHECK (length(strategic_relevance) BETWEEN 20 AND 2000),
  publisher text NOT NULL,
  source_title text NOT NULL,
  source_url text NOT NULL CHECK (source_url ~ '^https://'),
  published_on date,
  retrieved_at timestamptz NOT NULL DEFAULT now(),
  data_nature market_intelligence.data_nature NOT NULL DEFAULT 'third_party',
  confidence numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  methodology_notes text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((metric_value IS NULL) = (metric_unit IS NULL))
);

CREATE INDEX market_evidence_country_category_idx
  ON market_intelligence.market_evidence(country_code, category);
CREATE INDEX market_evidence_metric_period_idx
  ON market_intelligence.market_evidence(metric_key, period_end DESC)
  WHERE metric_key IS NOT NULL;
CREATE INDEX market_evidence_source_id_idx
  ON market_intelligence.market_evidence(source_id);

CREATE TRIGGER market_evidence_set_updated_at
BEFORE UPDATE ON market_intelligence.market_evidence
FOR EACH ROW EXECUTE FUNCTION market_intelligence.set_updated_at();

ALTER TABLE market_intelligence.market_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE market_intelligence.market_evidence FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE market_intelligence.market_evidence TO service_role;

INSERT INTO market_intelligence.sources (
  source_key, display_name, kind, status, base_url, documentation_url,
  collection_method, data_nature, default_confidence, retention_days, config_schema
) VALUES (
  'codex_public_research',
  'Codex public-source research',
  'manual_import',
  'enabled',
  NULL,
  'https://developers.openai.com/codex/',
  'manual',
  'third_party',
  0.9,
  3650,
  '{"requires_source_url":true,"stores_paraphrased_claims_only":true}'::jsonb
)
ON CONFLICT (source_key) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  status = EXCLUDED.status,
  collection_method = EXCLUDED.collection_method,
  data_nature = EXCLUDED.data_nature,
  default_confidence = EXCLUDED.default_confidence,
  retention_days = EXCLUDED.retention_days,
  config_schema = EXCLUDED.config_schema,
  updated_at = now();
