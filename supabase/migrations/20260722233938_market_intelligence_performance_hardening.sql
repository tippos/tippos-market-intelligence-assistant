-- Market Intelligence performance hardening after Supabase advisor review.
-- Keep foreign-key maintenance and common joins efficient as ingestion volume grows.

CREATE INDEX IF NOT EXISTS access_roles_granted_by_idx
  ON market_intelligence.access_roles(granted_by);
CREATE INDEX IF NOT EXISTS ai_prompts_language_code_idx
  ON market_intelligence.ai_prompts(language_code);
CREATE INDEX IF NOT EXISTS ai_prompts_topic_id_idx
  ON market_intelligence.ai_prompts(topic_id);
CREATE INDEX IF NOT EXISTS ai_responses_detected_language_code_idx
  ON market_intelligence.ai_responses(detected_language_code);
CREATE INDEX IF NOT EXISTS audit_log_actor_user_id_idx
  ON market_intelligence.audit_log(actor_user_id);
CREATE INDEX IF NOT EXISTS collection_jobs_connector_account_id_idx
  ON market_intelligence.collection_jobs(connector_account_id);
CREATE INDEX IF NOT EXISTS content_assets_language_code_idx
  ON market_intelligence.content_assets(language_code);
CREATE INDEX IF NOT EXISTS content_assets_topic_id_idx
  ON market_intelligence.content_assets(topic_id);
CREATE INDEX IF NOT EXISTS content_opportunities_keyword_id_idx
  ON market_intelligence.content_opportunities(keyword_id);
CREATE INDEX IF NOT EXISTS content_opportunities_language_code_idx
  ON market_intelligence.content_opportunities(language_code);
CREATE INDEX IF NOT EXISTS content_opportunities_topic_id_idx
  ON market_intelligence.content_opportunities(topic_id);
CREATE INDEX IF NOT EXISTS data_quality_issues_job_id_idx
  ON market_intelligence.data_quality_issues(job_id);
CREATE INDEX IF NOT EXISTS data_quality_issues_source_id_idx
  ON market_intelligence.data_quality_issues(source_id);
CREATE INDEX IF NOT EXISTS keyword_topics_topic_id_idx
  ON market_intelligence.keyword_topics(topic_id);
CREATE INDEX IF NOT EXISTS keyword_variants_language_code_idx
  ON market_intelligence.keyword_variants(language_code);
CREATE INDEX IF NOT EXISTS language_rollout_readiness_approved_by_idx
  ON market_intelligence.language_rollout_readiness(approved_by);
CREATE INDEX IF NOT EXISTS raw_observations_job_id_idx
  ON market_intelligence.raw_observations(job_id);
CREATE INDEX IF NOT EXISTS search_metrics_source_id_idx
  ON market_intelligence.search_metrics(source_id);
CREATE INDEX IF NOT EXISTS search_result_items_domain_id_idx
  ON market_intelligence.search_result_items(domain_id);
CREATE INDEX IF NOT EXISTS search_results_snapshots_source_id_idx
  ON market_intelligence.search_results_snapshots(source_id);
CREATE INDEX IF NOT EXISTS topics_parent_id_idx
  ON market_intelligence.topics(parent_id);

DROP POLICY IF EXISTS access_roles_read_self ON market_intelligence.access_roles;
CREATE POLICY access_roles_read_self ON market_intelligence.access_roles
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()));
