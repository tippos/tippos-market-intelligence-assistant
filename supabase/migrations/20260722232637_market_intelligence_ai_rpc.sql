-- AI visibility ingestion and retention maintenance.

CREATE OR REPLACE FUNCTION public.mi_record_ai_visibility(
  p_source_key text,
  p_prompt_key text,
  p_idempotency_key text,
  p_provider_model text,
  p_status text,
  p_response_summary jsonb,
  p_response_text text,
  p_retention_mode text,
  p_mentions jsonb,
  p_citations jsonb,
  p_metrics jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source market_intelligence.sources%ROWTYPE;
  v_prompt market_intelligence.ai_prompts%ROWTYPE;
  v_run_id uuid;
  v_item jsonb;
  v_brand_id uuid;
  v_domain_id uuid;
  v_domain text;
  v_url text;
  v_existing_status text;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  IF length(p_idempotency_key) NOT BETWEEN 8 AND 200
    OR length(p_provider_model) NOT BETWEEN 2 AND 200
    OR p_status NOT IN ('succeeded', 'failed', 'blocked_policy')
    OR p_retention_mode NOT IN ('full', 'summary', 'metadata_only')
    OR jsonb_typeof(p_response_summary) <> 'object'
    OR jsonb_typeof(p_mentions) <> 'array'
    OR jsonb_typeof(p_citations) <> 'array'
    OR jsonb_array_length(p_mentions) > 100
    OR jsonb_array_length(p_citations) > 100 THEN
    RAISE EXCEPTION 'invalid_ai_visibility_payload';
  END IF;
  IF p_retention_mode <> 'full' AND p_response_text IS NOT NULL THEN
    RAISE EXCEPTION 'full_text_not_allowed_for_retention_mode';
  END IF;

  SELECT * INTO v_source
    FROM market_intelligence.sources
   WHERE source_key = p_source_key AND kind IN ('ai_provider', 'synthetic');
  IF NOT FOUND OR v_source.status NOT IN ('enabled', 'mock', 'disabled_pending_credentials') THEN
    RAISE EXCEPTION 'source_not_enabled';
  END IF;
  SELECT * INTO v_prompt
    FROM market_intelligence.ai_prompts
   WHERE prompt_key = p_prompt_key AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'prompt_not_found'; END IF;

  SELECT id, status INTO v_run_id, v_existing_status
    FROM market_intelligence.ai_runs
   WHERE source_id = v_source.id AND idempotency_key = p_idempotency_key;
  IF FOUND AND v_existing_status = 'succeeded' THEN
    RETURN jsonb_build_object('ok', true, 'replayed', true, 'run_id', v_run_id);
  END IF;

  INSERT INTO market_intelligence.ai_runs
    (source_id, prompt_id, idempotency_key, provider_model, model_version, status,
     finished_at, latency_ms, input_tokens, output_tokens, cost_usd, response_hash, error_code)
  VALUES
    (v_source.id, v_prompt.id, p_idempotency_key, p_provider_model, p_metrics->>'model_version', p_status,
     now(), (p_metrics->>'latency_ms')::integer, (p_metrics->>'input_tokens')::integer,
     (p_metrics->>'output_tokens')::integer, (p_metrics->>'cost_usd')::numeric,
     md5(coalesce(p_response_text, '') || p_response_summary::text), p_metrics->>'error_code')
  ON CONFLICT (source_id, idempotency_key) DO UPDATE SET
    prompt_id = EXCLUDED.prompt_id,
    provider_model = EXCLUDED.provider_model,
    model_version = EXCLUDED.model_version,
    status = EXCLUDED.status,
    finished_at = EXCLUDED.finished_at,
    latency_ms = EXCLUDED.latency_ms,
    input_tokens = EXCLUDED.input_tokens,
    output_tokens = EXCLUDED.output_tokens,
    cost_usd = EXCLUDED.cost_usd,
    response_hash = EXCLUDED.response_hash,
    error_code = EXCLUDED.error_code,
    updated_at = now()
  RETURNING id INTO v_run_id;

  IF p_status = 'succeeded' THEN
    INSERT INTO market_intelligence.ai_responses
      (run_id, full_text, structured_summary, detected_language_code, retention_mode, expires_at)
    VALUES
      (v_run_id, p_response_text, p_response_summary, v_prompt.language_code, p_retention_mode,
       CASE WHEN p_retention_mode = 'full' THEN now() + make_interval(days => v_source.retention_days) ELSE NULL END)
    ON CONFLICT (run_id) DO UPDATE SET
      full_text = EXCLUDED.full_text,
      structured_summary = EXCLUDED.structured_summary,
      detected_language_code = EXCLUDED.detected_language_code,
      retention_mode = EXCLUDED.retention_mode,
      expires_at = EXCLUDED.expires_at;

    DELETE FROM market_intelligence.ai_mentions WHERE run_id = v_run_id;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_mentions)
    LOOP
      IF coalesce(length(v_item->>'brand_key'), 0) NOT BETWEEN 1 AND 100 THEN
        RAISE EXCEPTION 'invalid_ai_mention';
      END IF;
      INSERT INTO market_intelligence.brands
        (brand_key, display_name, category, is_tippos, aliases, evidence_url)
      VALUES
        (market_intelligence.normalize_text(v_item->>'brand_key'),
         coalesce(nullif(v_item->>'display_name', ''), v_item->>'brand_key'),
         coalesce(nullif(v_item->>'category', ''), 'observed_competitor'),
         market_intelligence.normalize_text(v_item->>'brand_key') = 'tippos',
         ARRAY[coalesce(nullif(v_item->>'display_name', ''), v_item->>'brand_key')],
         v_item->>'evidence_url')
      ON CONFLICT (brand_key) DO UPDATE SET
        display_name = EXCLUDED.display_name,
        evidence_url = coalesce(EXCLUDED.evidence_url, market_intelligence.brands.evidence_url),
        updated_at = now()
      RETURNING id INTO v_brand_id;

      INSERT INTO market_intelligence.ai_mentions
        (run_id, brand_id, mention_position, sentiment, recommendation_strength, context_summary, confidence)
      VALUES
        (v_run_id, v_brand_id, (v_item->>'position')::integer, (v_item->>'sentiment')::numeric,
         (v_item->>'recommendation_strength')::numeric, v_item->>'context_summary',
         coalesce((v_item->>'confidence')::numeric, v_source.default_confidence));
    END LOOP;

    DELETE FROM market_intelligence.ai_citations WHERE run_id = v_run_id;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_citations)
    LOOP
      v_url := v_item->>'url';
      v_domain := lower(substring(v_url from '^https?://([^/:?#]+)'));
      IF v_domain IS NULL OR length(v_url) > 2048 THEN
        RAISE EXCEPTION 'invalid_ai_citation';
      END IF;
      INSERT INTO market_intelligence.domains (domain, display_name, is_tippos)
      VALUES (v_domain, v_domain, v_domain IN ('tippos.com', 'www.tippos.com', 'tippos.lovable.app'))
      ON CONFLICT (domain) DO UPDATE SET updated_at = now()
      RETURNING id INTO v_domain_id;

      INSERT INTO market_intelligence.ai_citations
        (run_id, citation_order, url, canonical_url, domain_id, title, is_tippos)
      VALUES
        (v_run_id, (v_item->>'order')::integer, v_url, coalesce(nullif(v_item->>'canonical_url', ''), v_url),
         v_domain_id, v_item->>'title', v_domain IN ('tippos.com', 'www.tippos.com', 'tippos.lovable.app'));
    END LOOP;

    IF v_source.status = 'disabled_pending_credentials' THEN
      UPDATE market_intelligence.sources
         SET status = 'enabled', last_success_at = now()
       WHERE id = v_source.id;
    ELSE
      UPDATE market_intelligence.sources SET last_success_at = now() WHERE id = v_source.id;
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', true, 'replayed', false, 'run_id', v_run_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.mi_cleanup_expired_data()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_raw integer;
  v_responses integer;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  DELETE FROM market_intelligence.raw_observations WHERE expires_at <= now();
  GET DIAGNOSTICS v_raw = ROW_COUNT;
  UPDATE market_intelligence.ai_responses
     SET full_text = NULL, retention_mode = 'summary', expires_at = NULL
   WHERE expires_at IS NOT NULL AND expires_at <= now() AND full_text IS NOT NULL;
  GET DIAGNOSTICS v_responses = ROW_COUNT;
  RETURN jsonb_build_object('raw_observations_deleted', v_raw, 'full_responses_reduced_to_summary', v_responses);
END;
$$;

CREATE OR REPLACE FUNCTION public.mi_get_active_prompts(p_prompt_keys text[] DEFAULT NULL)
RETURNS TABLE(prompt_key text, prompt_text text, language_code text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT p.prompt_key, p.prompt_text, p.language_code
      FROM market_intelligence.ai_prompts p
     WHERE p.active AND (p_prompt_keys IS NULL OR p.prompt_key = ANY(p_prompt_keys))
     ORDER BY p.prompt_key
     LIMIT 100;
END;
$$;

REVOKE ALL ON FUNCTION public.mi_record_ai_visibility(text,text,text,text,text,jsonb,text,text,jsonb,jsonb,jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_record_ai_visibility(text,text,text,text,text,jsonb,text,text,jsonb,jsonb,jsonb)
  TO service_role;
REVOKE ALL ON FUNCTION public.mi_cleanup_expired_data() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_cleanup_expired_data() TO service_role;
REVOKE ALL ON FUNCTION public.mi_get_active_prompts(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_get_active_prompts(text[]) TO service_role;
