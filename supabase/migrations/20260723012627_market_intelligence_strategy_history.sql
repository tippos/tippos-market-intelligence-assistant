CREATE TABLE market_intelligence.strategy_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope text NOT NULL DEFAULT 'US' CHECK (scope IN ('US')),
  question text NOT NULL CHECK (length(question) BETWEEN 1 AND 1000),
  answer text NOT NULL CHECK (length(answer) BETWEEN 1 AND 50000),
  model text NOT NULL CHECK (length(model) BETWEEN 1 AND 100),
  evidence_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(evidence_snapshot) = 'array'),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX strategy_history_created_at_idx
  ON market_intelligence.strategy_history(created_at DESC);

ALTER TABLE market_intelligence.strategy_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON market_intelligence.strategy_history FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.mi_save_strategy(
  p_question text,
  p_answer text,
  p_model text,
  p_evidence_snapshot jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_id uuid;
BEGIN
  IF coalesce((SELECT auth.jwt() ->> 'role'), '') <> 'service_role' THEN
    RAISE EXCEPTION 'market_intelligence_forbidden' USING ERRCODE = '42501';
  END IF;
  INSERT INTO market_intelligence.strategy_history(question, answer, model, evidence_snapshot)
  VALUES (p_question, p_answer, p_model, p_evidence_snapshot)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.mi_list_strategies(p_limit integer DEFAULT 50)
RETURNS TABLE (id uuid, question text, answer text, model text, evidence_snapshot jsonb, created_at timestamptz)
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
  SELECT h.id, h.question, h.answer, h.model, h.evidence_snapshot, h.created_at
  FROM market_intelligence.strategy_history h
  ORDER BY h.created_at DESC
  LIMIT least(greatest(coalesce(p_limit, 50), 1), 100);
END;
$$;

REVOKE ALL ON FUNCTION public.mi_save_strategy(text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mi_list_strategies(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mi_save_strategy(text, text, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.mi_list_strategies(integer) TO service_role;
