-- Official Google Trends manual exports. Values are relative indices, never search-volume estimates.
INSERT INTO market_intelligence.sources
  (source_key, display_name, kind, status, base_url, documentation_url, terms_url,
   collection_method, data_nature, default_confidence, retention_days, config_schema)
VALUES
  ('google_trends', 'Google Trends manual CSV exports', 'trends', 'enabled',
   'https://trends.google.com', 'https://support.google.com/trends/answer/4365538',
   'https://policies.google.com/terms', 'manual', 'third_party', 0.750, 3650,
   jsonb_build_object('unit', 'relative_interest_index_0_100', 'search_counts', false,
     'manual_export_required', true))
ON CONFLICT (source_key) DO UPDATE SET display_name = EXCLUDED.display_name,
  status = EXCLUDED.status, config_schema = EXCLUDED.config_schema, updated_at = now();

CREATE TABLE IF NOT EXISTS market_intelligence.trends_imports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id uuid NOT NULL REFERENCES market_intelligence.sources(id) ON DELETE RESTRICT,
  query_text text NOT NULL,
  normalized_query text NOT NULL,
  country_code text NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
  category text NOT NULL DEFAULT 'All categories',
  search_type text NOT NULL DEFAULT 'Web Search',
  period_start date, period_end date,
  extracted_at timestamptz NOT NULL DEFAULT now(),
  file_checksum text NOT NULL UNIQUE,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT trends_imports_period_order CHECK (
    period_start IS NULL OR period_end IS NULL OR period_start <= period_end
  ),
  CONSTRAINT trends_imports_metadata_object CHECK (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trends_imports_source_id_idx
  ON market_intelligence.trends_imports (source_id);
CREATE INDEX IF NOT EXISTS trends_imports_query_country_period_idx
  ON market_intelligence.trends_imports
  (normalized_query, country_code, period_start, period_end);

CREATE TABLE IF NOT EXISTS market_intelligence.trends_geo_metrics (
  import_id uuid NOT NULL REFERENCES market_intelligence.trends_imports(id) ON DELETE CASCADE,
  region_name text NOT NULL, region_code text, raw_value text,
  relative_interest numeric(6,2) CHECK (relative_interest BETWEEN 0 AND 100),
  is_suppressed boolean NOT NULL DEFAULT false, PRIMARY KEY (import_id, region_name)
);
CREATE TABLE IF NOT EXISTS market_intelligence.trends_related_terms (
  import_id uuid NOT NULL REFERENCES market_intelligence.trends_imports(id) ON DELETE CASCADE,
  relation_kind text NOT NULL CHECK (relation_kind IN ('topic','query')),
  ranking_kind text NOT NULL CHECK (ranking_kind IN ('top','rising')),
  rank integer NOT NULL CHECK (rank > 0), term text NOT NULL, raw_value text NOT NULL,
  score numeric(10,2), is_breakout boolean NOT NULL DEFAULT false,
  PRIMARY KEY (import_id, relation_kind, ranking_kind, rank)
);
REVOKE ALL ON market_intelligence.trends_imports, market_intelligence.trends_geo_metrics,
  market_intelligence.trends_related_terms FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON market_intelligence.trends_imports,
  market_intelligence.trends_geo_metrics, market_intelligence.trends_related_terms TO service_role;
