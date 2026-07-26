-- Remove fabricated and non-production Market Intelligence records from the
-- standalone project. Verified third-party evidence and manually observed
-- autocomplete/SERP records are intentionally preserved.

DELETE FROM market_intelligence.content_opportunities;
DELETE FROM market_intelligence.keyword_variants;
DELETE FROM market_intelligence.language_market_scores;
DELETE FROM market_intelligence.language_rollout_readiness;

UPDATE market_intelligence.languages
   SET estimated_localization_cost = NULL,
       updated_at = now()
 WHERE estimated_localization_cost IS NOT NULL;

DELETE FROM market_intelligence.market_evidence
 WHERE data_nature = 'inferred'
   AND source_id = (
     SELECT id FROM market_intelligence.sources
      WHERE source_key = 'tippos_product_hypotheses'
   );

DELETE FROM market_intelligence.ai_runs r
 WHERE r.idempotency_key ILIKE '%smoke%'
    OR r.source_id = (
      SELECT id FROM market_intelligence.sources
       WHERE source_key = 'synthetic_fixture'
    );

DELETE FROM market_intelligence.ai_prompt_sets
 WHERE set_key = 'language-discovery-v1';

DELETE FROM market_intelligence.raw_observations ro
 WHERE ro.data_nature = 'synthetic'
    OR ro.source_id = (
      SELECT id FROM market_intelligence.sources
       WHERE source_key = 'synthetic_fixture'
    );

DELETE FROM market_intelligence.collection_jobs j
 WHERE j.source_id = (
   SELECT id FROM market_intelligence.sources
    WHERE source_key = 'synthetic_fixture'
 );

DELETE FROM market_intelligence.search_metrics
 WHERE data_nature = 'synthetic';

DELETE FROM market_intelligence.keywords k
 WHERE k.created_at = timestamptz '2026-07-22 23:26:23.149167+00'
    OR (
      k.original_text = 'digital tipping'
      AND k.country_code = 'US'
      AND k.created_at = timestamptz '2026-07-22 23:33:22.137422+00'
    );

DELETE FROM market_intelligence.domains d
 WHERE d.domain = 'example.com'
   AND NOT EXISTS (
     SELECT 1 FROM market_intelligence.ai_citations c WHERE c.domain_id = d.id
   )
   AND NOT EXISTS (
     SELECT 1 FROM market_intelligence.search_result_items i WHERE i.domain_id = d.id
   );

DELETE FROM market_intelligence.sources
 WHERE source_key IN ('synthetic_fixture', 'tippos_product_hypotheses');

UPDATE market_intelligence.collection_jobs
   SET metadata = (metadata - 'fixture')
     || jsonb_build_object('source_file', metadata ->> 'fixture')
 WHERE metadata ? 'fixture'
   AND source_id = (
     SELECT id FROM market_intelligence.sources
      WHERE source_key = 'codex_public_research'
   );

ALTER TABLE market_intelligence.sources
  ADD CONSTRAINT sources_production_data_only
  CHECK (
    kind <> 'synthetic'
    AND status <> 'mock'
    AND collection_method <> 'mock'
    AND data_nature <> 'synthetic'
  );

ALTER TABLE market_intelligence.raw_observations
  ADD CONSTRAINT raw_observations_no_synthetic_data
  CHECK (data_nature <> 'synthetic');

ALTER TABLE market_intelligence.search_metrics
  ADD CONSTRAINT search_metrics_no_synthetic_data
  CHECK (data_nature <> 'synthetic');

ALTER TABLE market_intelligence.market_evidence
  ADD CONSTRAINT market_evidence_no_synthetic_data
  CHECK (data_nature <> 'synthetic');

ALTER TABLE market_intelligence.ai_runs
  ADD CONSTRAINT ai_runs_no_test_models
  CHECK (
    provider_model !~* '(^|[-_ ])(mock|demo|test|placeholder|synthetic)([-_ ]|$)'
  );

ALTER TABLE market_intelligence.language_market_scores
  ADD CONSTRAINT language_scores_require_observations
  CHECK (
    coalesce((rationale ->> 'observed_days')::integer, 0) > 0
    OR coalesce((rationale ->> 'ai_runs')::integer, 0) > 0
  );

CREATE OR REPLACE FUNCTION market_intelligence.reject_unobserved_language_score()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF coalesce((NEW.rationale ->> 'observed_days')::integer, 0) = 0
     AND coalesce((NEW.rationale ->> 'ai_runs')::integer, 0) = 0 THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER language_scores_require_real_observations
BEFORE INSERT OR UPDATE ON market_intelligence.language_market_scores
FOR EACH ROW EXECUTE FUNCTION market_intelligence.reject_unobserved_language_score();
