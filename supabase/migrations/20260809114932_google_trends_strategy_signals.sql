-- Google Trends exports are manually downloaded CSV files. They provide
-- relative interest, not search-volume estimates, and remain private to the
-- server-side strategy assistant.
CREATE TABLE IF NOT EXISTS market_intelligence.trends_interest_over_time (
  import_id uuid NOT NULL REFERENCES market_intelligence.trends_imports(id) ON DELETE CASCADE,
  observed_on date NOT NULL,
  raw_value text NOT NULL,
  relative_interest numeric(6,2) CHECK (relative_interest BETWEEN 0 AND 100),
  is_suppressed boolean NOT NULL DEFAULT false,
  PRIMARY KEY (import_id, observed_on)
);

CREATE INDEX IF NOT EXISTS trends_interest_over_time_import_observed_idx
  ON market_intelligence.trends_interest_over_time (import_id, observed_on DESC);
-- The initial manual-import migration intended this index, but the current
-- hosted project does not have it. Keep this correction idempotent.
CREATE INDEX IF NOT EXISTS trends_imports_source_id_idx
  ON market_intelligence.trends_imports (source_id);
CREATE INDEX IF NOT EXISTS trends_imports_query_country_period_idx
  ON market_intelligence.trends_imports
  (normalized_query, country_code, period_start, period_end);
CREATE INDEX IF NOT EXISTS trends_imports_strategy_dataset_idx
  ON market_intelligence.trends_imports (
    source_id, country_code, normalized_query, (metadata ->> 'dataset_kind'), extracted_at DESC
  );

-- The hosted first-pass migration used a different timestamp and omitted these
-- checks. Add them before its history entry is reconciled to the checked-in
-- migration, preserving the original manual-import contract.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'trends_imports_period_order'
      AND conrelid = 'market_intelligence.trends_imports'::regclass
  ) THEN
    ALTER TABLE market_intelligence.trends_imports
      ADD CONSTRAINT trends_imports_period_order CHECK (
        period_start IS NULL OR period_end IS NULL OR period_start <= period_end
      );
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'trends_imports_metadata_object'
      AND conrelid = 'market_intelligence.trends_imports'::regclass
  ) THEN
    ALTER TABLE market_intelligence.trends_imports
      ADD CONSTRAINT trends_imports_metadata_object CHECK (jsonb_typeof(metadata) = 'object');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'trends_geo_metrics_relative_interest_check'
      AND conrelid = 'market_intelligence.trends_geo_metrics'::regclass
  ) THEN
    ALTER TABLE market_intelligence.trends_geo_metrics
      ADD CONSTRAINT trends_geo_metrics_relative_interest_check
      CHECK (relative_interest BETWEEN 0 AND 100);
  END IF;
END;
$$;

ALTER TABLE market_intelligence.trends_interest_over_time ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON market_intelligence.trends_interest_over_time FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON market_intelligence.trends_interest_over_time TO service_role;

CREATE OR REPLACE FUNCTION public.mi_import_google_trends_export(
  p_query_text text,
  p_country_code text,
  p_category text,
  p_search_type text,
  p_period_start date,
  p_period_end date,
  p_dataset_kind text,
  p_file_checksum text,
  p_metadata jsonb,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source_id uuid;
  v_import_id uuid;
  v_item jsonb;
  v_loaded integer := 0;
  v_relation_kind text;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  IF length(btrim(p_query_text)) NOT BETWEEN 1 AND 500
    OR upper(p_country_code) <> 'US'
    OR p_dataset_kind NOT IN (
      'interest_over_time', 'interest_by_subregion', 'related_queries', 'related_topics'
    )
    OR p_file_checksum !~ '^[a-f0-9]{64}$'
    OR jsonb_typeof(p_metadata) <> 'object'
    OR jsonb_typeof(p_payload) <> 'object'
    OR (p_period_start IS NOT NULL AND p_period_end IS NOT NULL AND p_period_start > p_period_end) THEN
    RAISE EXCEPTION 'invalid_google_trends_export';
  END IF;

  SELECT id INTO v_source_id
  FROM market_intelligence.sources
  WHERE source_key = 'google_trends' AND status = 'enabled';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'google_trends_source_not_enabled';
  END IF;

  INSERT INTO market_intelligence.trends_imports (
    source_id, query_text, normalized_query, country_code, category, search_type,
    period_start, period_end, file_checksum, metadata
  ) VALUES (
    v_source_id, btrim(p_query_text), market_intelligence.normalize_text(p_query_text), 'US',
    coalesce(nullif(btrim(p_category), ''), 'All categories'),
    coalesce(nullif(btrim(p_search_type), ''), 'Web Search'),
    p_period_start, p_period_end, p_file_checksum,
    p_metadata || jsonb_build_object(
      'dataset_kind', p_dataset_kind,
      'metric_interpretation', 'relative_interest_index_0_100_not_search_volume'
    )
  )
  ON CONFLICT (file_checksum) DO UPDATE SET
    query_text = EXCLUDED.query_text,
    normalized_query = EXCLUDED.normalized_query,
    country_code = EXCLUDED.country_code,
    category = EXCLUDED.category,
    search_type = EXCLUDED.search_type,
    period_start = EXCLUDED.period_start,
    period_end = EXCLUDED.period_end,
    metadata = EXCLUDED.metadata,
    extracted_at = now()
  RETURNING id INTO v_import_id;

  IF p_dataset_kind = 'interest_over_time' THEN
    IF jsonb_typeof(p_payload -> 'interest_over_time') <> 'array'
      OR jsonb_array_length(p_payload -> 'interest_over_time') NOT BETWEEN 1 AND 5000 THEN
      RAISE EXCEPTION 'invalid_google_trends_interest_rows';
    END IF;
    DELETE FROM market_intelligence.trends_interest_over_time WHERE import_id = v_import_id;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload -> 'interest_over_time')
    LOOP
      IF jsonb_typeof(v_item) <> 'object'
        OR nullif(v_item ->> 'observed_on', '') IS NULL
        OR nullif(v_item ->> 'raw_value', '') IS NULL
        OR (v_item ->> 'relative_interest') IS NOT NULL
           AND ((v_item ->> 'relative_interest')::numeric < 0 OR (v_item ->> 'relative_interest')::numeric > 100) THEN
        RAISE EXCEPTION 'invalid_google_trends_interest_row';
      END IF;
      INSERT INTO market_intelligence.trends_interest_over_time (
        import_id, observed_on, raw_value, relative_interest, is_suppressed
      ) VALUES (
        v_import_id, (v_item ->> 'observed_on')::date, left(v_item ->> 'raw_value', 100),
        (v_item ->> 'relative_interest')::numeric, coalesce((v_item ->> 'is_suppressed')::boolean, false)
      );
      v_loaded := v_loaded + 1;
    END LOOP;
  ELSIF p_dataset_kind = 'interest_by_subregion' THEN
    IF jsonb_typeof(p_payload -> 'geo_metrics') <> 'array'
      OR jsonb_array_length(p_payload -> 'geo_metrics') NOT BETWEEN 1 AND 5000 THEN
      RAISE EXCEPTION 'invalid_google_trends_geo_rows';
    END IF;
    DELETE FROM market_intelligence.trends_geo_metrics WHERE import_id = v_import_id;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload -> 'geo_metrics')
    LOOP
      IF jsonb_typeof(v_item) <> 'object'
        OR length(btrim(coalesce(v_item ->> 'region_name', ''))) NOT BETWEEN 1 AND 240
        OR nullif(v_item ->> 'raw_value', '') IS NULL
        OR (v_item ->> 'relative_interest') IS NOT NULL
           AND ((v_item ->> 'relative_interest')::numeric < 0 OR (v_item ->> 'relative_interest')::numeric > 100) THEN
        RAISE EXCEPTION 'invalid_google_trends_geo_row';
      END IF;
      INSERT INTO market_intelligence.trends_geo_metrics (
        import_id, region_name, region_code, raw_value, relative_interest, is_suppressed
      ) VALUES (
        v_import_id, btrim(v_item ->> 'region_name'), nullif(btrim(v_item ->> 'region_code'), ''),
        left(v_item ->> 'raw_value', 100), (v_item ->> 'relative_interest')::numeric,
        coalesce((v_item ->> 'is_suppressed')::boolean, false)
      );
      v_loaded := v_loaded + 1;
    END LOOP;
  ELSE
    v_relation_kind := CASE p_dataset_kind
      WHEN 'related_queries' THEN 'query'
      WHEN 'related_topics' THEN 'topic'
    END;
    IF jsonb_typeof(p_payload -> 'related_terms') <> 'array'
      OR jsonb_array_length(p_payload -> 'related_terms') NOT BETWEEN 1 AND 200 THEN
      RAISE EXCEPTION 'invalid_google_trends_related_rows';
    END IF;
    DELETE FROM market_intelligence.trends_related_terms
    WHERE import_id = v_import_id AND relation_kind = v_relation_kind;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload -> 'related_terms')
    LOOP
      IF jsonb_typeof(v_item) <> 'object'
        OR v_item ->> 'ranking_kind' NOT IN ('top', 'rising')
        OR coalesce((v_item ->> 'rank')::integer, 0) < 1
        OR length(btrim(coalesce(v_item ->> 'term', ''))) NOT BETWEEN 1 AND 500
        OR nullif(v_item ->> 'raw_value', '') IS NULL THEN
        RAISE EXCEPTION 'invalid_google_trends_related_row';
      END IF;
      INSERT INTO market_intelligence.trends_related_terms (
        import_id, relation_kind, ranking_kind, rank, term, raw_value, score, is_breakout
      ) VALUES (
        v_import_id, v_relation_kind, v_item ->> 'ranking_kind', (v_item ->> 'rank')::integer,
        btrim(v_item ->> 'term'), left(v_item ->> 'raw_value', 100),
        (v_item ->> 'score')::numeric, coalesce((v_item ->> 'is_breakout')::boolean, false)
      );
      v_loaded := v_loaded + 1;
    END LOOP;
  END IF;

  UPDATE market_intelligence.sources
  SET last_success_at = now(), updated_at = now()
  WHERE id = v_source_id AND v_loaded > 0;

  RETURN jsonb_build_object(
    'ok', true, 'import_id', v_import_id, 'dataset_kind', p_dataset_kind, 'loaded', v_loaded
  );
END;
$$;

REVOKE ALL ON FUNCTION public.mi_import_google_trends_export(
  text, text, text, text, date, date, text, text, jsonb, jsonb
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_import_google_trends_export(
  text, text, text, text, date, date, text, text, jsonb, jsonb
) TO service_role;

CREATE OR REPLACE FUNCTION public.mi_get_us_strategy_google_trends_evidence()
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
  WITH latest_time_imports AS (
    SELECT DISTINCT ON (ti.normalized_query) ti.*
    FROM market_intelligence.trends_imports ti
    JOIN market_intelligence.sources s ON s.id = ti.source_id
    WHERE s.source_key = 'google_trends'
      AND ti.country_code = 'US'
      AND ti.metadata ->> 'dataset_kind' = 'interest_over_time'
    ORDER BY ti.normalized_query, ti.extracted_at DESC
  ), latest_time_values AS (
    SELECT DISTINCT ON (it.import_id)
      it.import_id, it.relative_interest AS latest_interest
    FROM market_intelligence.trends_interest_over_time it
    JOIN latest_time_imports ti ON ti.id = it.import_id
    WHERE NOT it.is_suppressed AND it.relative_interest IS NOT NULL
    ORDER BY it.import_id, it.observed_on DESC
  ), time_evidence AS (
    SELECT
      'google-trends-time-' || ti.id::text AS evidence_key,
      'Google Trends'::text AS category,
      'relative_interest_index'::text AS metric_key,
      max(it.relative_interest) AS metric_value,
      'relative interest index (0-100; not search volume)'::text AS metric_unit,
      min(it.observed_on) AS period_start,
      max(it.observed_on) AS period_end,
      'Google Trends manual export for "' || ti.query_text || '" peaked at a relative-interest index of '
        || max(it.relative_interest)::text || ' out of 100; its latest recorded index was '
        || coalesce(ltv.latest_interest::text, 'suppressed') || '.' AS claim_summary,
      'Use only to compare interest within this exact Google Trends export, not as market size or search volume.'::text AS strategic_relevance,
      'Google Trends'::text AS publisher,
      'Manual CSV export: ' || ti.query_text AS source_title,
      'https://trends.google.com/trends/'::text AS source_url,
      ti.extracted_at::date AS published_on,
      0.750::numeric AS confidence
    FROM latest_time_imports ti
    JOIN market_intelligence.trends_interest_over_time it ON it.import_id = ti.id
    LEFT JOIN latest_time_values ltv ON ltv.import_id = ti.id
    WHERE NOT it.is_suppressed AND it.relative_interest IS NOT NULL
    GROUP BY ti.id, ti.query_text, ti.extracted_at, ltv.latest_interest
  ), latest_geo_imports AS (
    SELECT DISTINCT ON (ti.normalized_query) ti.*
    FROM market_intelligence.trends_imports ti
    JOIN market_intelligence.sources s ON s.id = ti.source_id
    WHERE s.source_key = 'google_trends'
      AND ti.country_code = 'US'
      AND ti.metadata ->> 'dataset_kind' = 'interest_by_subregion'
    ORDER BY ti.normalized_query, ti.extracted_at DESC
  ), geo_evidence AS (
    SELECT * FROM (
      SELECT
        'google-trends-geo-' || ti.id::text || '-' || row_number() OVER (
          PARTITION BY ti.id ORDER BY gm.relative_interest DESC, gm.region_name
        )::text AS evidence_key,
        'Google Trends'::text AS category,
        'relative_interest_index'::text AS metric_key,
        gm.relative_interest AS metric_value,
        'relative interest index (0-100; not search volume)'::text AS metric_unit,
        ti.period_start,
        ti.period_end,
        'Google Trends manual export for "' || ti.query_text || '" recorded a relative-interest index of '
          || gm.relative_interest::text || ' in ' || gm.region_name || '.' AS claim_summary,
        'This is a relative geographic signal in this export only; do not infer audience size or total demand.'::text AS strategic_relevance,
        'Google Trends'::text AS publisher,
        'Manual CSV export: ' || ti.query_text || ' by subregion' AS source_title,
        'https://trends.google.com/trends/'::text AS source_url,
        ti.extracted_at::date AS published_on,
        0.750::numeric AS confidence,
        row_number() OVER (PARTITION BY ti.id ORDER BY gm.relative_interest DESC, gm.region_name) AS rank_in_export
      FROM latest_geo_imports ti
      JOIN market_intelligence.trends_geo_metrics gm ON gm.import_id = ti.id
      WHERE NOT gm.is_suppressed AND gm.relative_interest IS NOT NULL
    ) ranked WHERE rank_in_export <= 5
  ), latest_related_imports AS (
    SELECT DISTINCT ON (ti.normalized_query, ti.metadata ->> 'dataset_kind') ti.*
    FROM market_intelligence.trends_imports ti
    JOIN market_intelligence.sources s ON s.id = ti.source_id
    WHERE s.source_key = 'google_trends'
      AND ti.country_code = 'US'
      AND ti.metadata ->> 'dataset_kind' IN ('related_queries', 'related_topics')
    ORDER BY ti.normalized_query, ti.metadata ->> 'dataset_kind', ti.extracted_at DESC
  ), related_evidence AS (
    SELECT
      'google-trends-related-' || ti.id::text || '-' || rt.relation_kind || '-' || rt.ranking_kind || '-' || rt.rank::text AS evidence_key,
      'Google Trends'::text AS category,
      'related_' || rt.relation_kind || '_' || rt.ranking_kind AS metric_key,
      rt.score AS metric_value,
      CASE WHEN rt.is_breakout THEN 'Breakout related term (not search volume)'
           ELSE 'related-term ranking score (not search volume)' END::text AS metric_unit,
      ti.period_start,
      ti.period_end,
      'Google Trends manual export lists "' || rt.term || '" as a ' || rt.ranking_kind
        || ' related ' || rt.relation_kind || ' for "' || ti.query_text || '".' AS claim_summary,
      'Treat related terms as query-context ideas to validate, not as demand estimates or guaranteed trends.'::text AS strategic_relevance,
      'Google Trends'::text AS publisher,
      'Manual CSV export: related ' || rt.relation_kind || ' for ' || ti.query_text AS source_title,
      'https://trends.google.com/trends/'::text AS source_url,
      ti.extracted_at::date AS published_on,
      0.750::numeric AS confidence
    FROM latest_related_imports ti
    JOIN market_intelligence.trends_related_terms rt ON rt.import_id = ti.id
    WHERE rt.rank <= 8
  )
  SELECT evidence_key, category, metric_key, metric_value, metric_unit, period_start, period_end,
    claim_summary, strategic_relevance, publisher, source_title, source_url, published_on, confidence
  FROM time_evidence
  UNION ALL
  SELECT evidence_key, category, metric_key, metric_value, metric_unit, period_start, period_end,
    claim_summary, strategic_relevance, publisher, source_title, source_url, published_on, confidence
  FROM geo_evidence
  UNION ALL
  SELECT evidence_key, category, metric_key, metric_value, metric_unit, period_start, period_end,
    claim_summary, strategic_relevance, publisher, source_title, source_url, published_on, confidence
  FROM related_evidence
  ORDER BY confidence DESC, evidence_key ASC
  LIMIT 60;
$$;

REVOKE ALL ON FUNCTION public.mi_get_us_strategy_google_trends_evidence()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_get_us_strategy_google_trends_evidence() TO service_role;
