import {
  adminClient,
  hasBackendAccess,
} from "../_shared/market_intelligence_runtime.ts";
import {
  extractOutputText,
  type OpenAIResponse,
} from "../_shared/openai_visibility.ts";
import {
  hasStrategyAccessCode,
  strategyAllowedOrigin,
  strategyClientHash,
} from "../_shared/strategy_access.ts";

const DEFAULT_MODEL = "gpt-5.6-terra";
const MAX_QUESTION_LENGTH = 1_000;
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": strategyAllowedOrigin(),
  "Access-Control-Allow-Headers":
    "content-type, x-strategy-access-code, apikey, authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

type Evidence = {
  evidence_key: string;
  category: string;
  metric_key: string | null;
  metric_value: number | null;
  metric_unit: string | null;
  period_start: string | null;
  period_end: string | null;
  claim_summary: string;
  strategic_relevance: string;
  publisher: string;
  source_title: string;
  source_url: string;
  published_on: string | null;
  confidence: number;
};

type SearchSignal = {
  query_text: string;
  use_case: string | null;
  industry: string | null;
  business_relevance: number;
  observed_on: string;
  country_code: string | null;
  source_key: string;
  confidence: number;
  interpretation: string;
};

type SavedStrategy = {
  id: string;
  question: string;
  answer: string;
  model: string;
  evidence_snapshot: unknown;
  created_at: string;
};

type GrowthSnapshot = Record<string, unknown>;

type StrategyAccessPreflight = {
  allowed: boolean;
  attempt_id?: number;
  reason?: string;
  retry_after_seconds?: number;
};

function response(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, ...extraHeaders },
  });
}

async function authorizeStrategyRequest(
  req: Request,
): Promise<Response | null> {
  if (await hasBackendAccess(req)) return null;

  const clientHash = await strategyClientHash(req);
  if (!clientHash) {
    return response({ error: "strategy_access_guard_misconfigured" }, 503);
  }

  const client = adminClient();
  const { data, error } = await client.rpc(
    "mi_reserve_strategy_access_attempt",
    {
      p_client_hash: clientHash,
    },
  );
  if (error || !data || typeof data !== "object" || Array.isArray(data)) {
    return response({ error: "strategy_access_guard_unavailable" }, 503);
  }

  const preflight = data as StrategyAccessPreflight;
  if (preflight.allowed !== true) {
    const retryAfter = Math.max(
      60,
      Math.min(3_600, Number(preflight.retry_after_seconds) || 900),
    );
    console.warn(
      "[market-intelligence-us-strategy] access_rate_limited",
      preflight.reason ?? "unknown",
    );
    return response(
      { error: "rate_limited", retry_after_seconds: retryAfter },
      429,
      { "Retry-After": String(retryAfter) },
    );
  }

  const attemptId = Number(preflight.attempt_id);
  if (!Number.isSafeInteger(attemptId) || attemptId <= 0) {
    return response({ error: "strategy_access_guard_unavailable" }, 503);
  }
  const accepted = await hasStrategyAccessCode(req);
  if (!accepted) return response({ error: "unauthorized" }, 401);

  const { error: auditError } = await client.rpc(
    "mi_finalize_strategy_access_attempt",
    {
      p_attempt_id: attemptId,
      p_client_hash: clientHash,
      p_succeeded: true,
    },
  );
  if (auditError) {
    return response({ error: "strategy_access_audit_unavailable" }, 503);
  }
  return null;
}

function evidenceContext(evidence: Evidence[]): string {
  return evidence.map((item) =>
    [
      `evidence_key: ${item.evidence_key}`,
      `category: ${item.category}`,
      `claim: ${item.claim_summary}`,
      `strategic_relevance: ${item.strategic_relevance}`,
      `period: ${item.period_start ?? "unknown"} to ${
        item.period_end ?? "unknown"
      }`,
      `publisher: ${item.publisher}`,
      `confidence: ${item.confidence}`,
    ].join("\n")
  ).join("\n\n");
}

function searchSignalContext(signals: SearchSignal[]): string {
  if (signals.length === 0) {
    return "No qualitative search signals are available.";
  }
  return signals.map((signal) =>
    [
      `query: ${signal.query_text}`,
      `use_case: ${signal.use_case ?? "unknown"}`,
      `industry: ${signal.industry ?? "unknown"}`,
      `business_relevance: ${signal.business_relevance}`,
      `observed_on: ${signal.observed_on}`,
      `country: ${signal.country_code ?? "unknown; do not infer"}`,
      `source_key: ${signal.source_key}`,
      `confidence: ${signal.confidence}`,
      `interpretation: ${signal.interpretation}`,
    ].join("\n")
  ).join("\n\n");
}

function strategyDigest(items: readonly SavedStrategy[]): string {
  if (!items.length) {
    return "No previous internal strategies are available to compare against.";
  }
  const seen = new Set<string>();
  const lines = items
    .filter((item) => {
      const key = `${item.question}|${item.model}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .slice(0, 12)
    .map((item) => {
      const answerSnippet =
        item.answer?.slice(0, 180).replace(/\s+/g, " ").trim() ||
        "(no details)";
      const when = new Date(item.created_at).toISOString().slice(0, 10);
      return `- [${when}] ${item.question} | ${answerSnippet}`;
    });
  return lines.join("\n");
}

function growthSnapshotContext(snapshot: GrowthSnapshot | null): string {
  if (!snapshot) return "No campaign performance snapshot is available.";
  return JSON.stringify(snapshot, null, 2);
}

async function askOpenAI(
  apiKey: string,
  question: string,
  evidence: Evidence[],
  searchSignals: SearchSignal[],
): Promise<OpenAIResponse> {
  const prompt = [
    "You are the private marketing-intelligence and growth-strategy assistant for tippos employees. tippos is a cashless tipping product used by people who give tips.",
    "tippos serves tip givers. Hotels, restaurants, salons, venues, and workers are tip contexts or possible distribution channels, not tippos customers or default partners.",
    "Optimize recommendations for marketing strategy and consumer adoption: search visibility, content, positioning, the tip giver's value, the first consumer segment, high-frequency tipping moments, acquisition loops, referral, and product flow.",
    "Never recommend finding a hotel, restaurant, salon, venue, or employer partner as the primary next step unless the founder explicitly asks about a distribution partnership. If you mention one, label it clearly as an optional distribution channel rather than the customer.",
    "Answer in plain English for a tippos employee making marketing decisions. Use only the supplied evidence for factual claims.",
    "Do not invent market size, search volume, adoption, customer demand, competitors, pricing, or legal conclusions.",
    "Autocomplete suggestions are qualitative evidence that a query formulation exists. Manual SERP snapshots are time/device/context-specific observations. Never treat either as search volume, universal popularity, universal rank, geography, or growth data.",
    "Distinguish evidence-backed observations from hypotheses. If evidence is insufficient, say so directly.",
    "Structure the response as: Direct answer; Why; Recommended next action; What to validate next; Evidence used.",
    "In Evidence used, cite public evidence keys in square brackets and identify autocomplete observations by their source_key.",
    `Founder question: ${question}`,
    "US evidence database:",
    evidenceContext(evidence),
    "Qualitative search and SERP signals (geography may be unknown):",
    searchSignalContext(searchSignals),
  ].join("\n\n");
  const result = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: Deno.env.get("OPENAI_US_STRATEGY_MODEL") || DEFAULT_MODEL,
      reasoning: { effort: "low" },
      max_output_tokens: 1_200,
      input: prompt,
    }),
    signal: AbortSignal.timeout(45_000),
  });
  const data = await result.json().catch(() => ({})) as OpenAIResponse;
  if (!result.ok) throw new Error(`openai_${result.status}`);
  return data;
}

async function askOpenAIWithHistory(
  apiKey: string,
  question: string,
  evidence: Evidence[],
  searchSignals: SearchSignal[],
  strategyHistory: SavedStrategy[],
  growthSnapshot: GrowthSnapshot | null,
): Promise<OpenAIResponse> {
  const prompt = [
    "You are the private marketing-intelligence and growth-strategy assistant for tippos employees.",
    "tippos is a cashless tipping product used by people who give tips.",
    "tippos serves tip givers. Hotels, restaurants, salons, venues, and workers are tip contexts or possible distribution channels, not tippos customers or default partners.",
    "Optimize recommendations for marketing strategy and consumer adoption: search visibility, content, positioning, the tip giver's value, the first consumer segment, high-frequency tipping moments, acquisition loops, referral, and product flow.",
    "Never recommend finding a hotel, restaurant, salon, venue, or employer partner as the primary next step unless the founder explicitly asks about a distribution partnership. If you mention one, label it clearly as an optional distribution channel rather than the customer.",
    "Use evidence from both saved internal strategies and the current market signals so email copy stays consistent with the brand learnings.",
    "Answer in plain English for a tippos employee making marketing decisions. Use only provided evidence for factual claims.",
    "Do not invent market size, search volume, adoption, customer demand, competitors, pricing, or legal conclusions.",
    "Autocomplete suggestions are qualitative evidence that a query formulation exists. Manual SERP snapshots are time/device/context-specific observations. Never treat either as search volume, universal popularity, universal rank, geography, or growth data.",
    "Distinguish evidence-backed observations from hypotheses. If evidence is insufficient, say so directly.",
    "The campaign snapshot contains aggregate Search Console, consented first-party events, and authoritative pilot signup totals. Never infer personal behavior or identify an individual from it.",
    "When campaign data is available, compare reach, engagement, pilot intent, and completed signup signals before proposing a change. Prefer one measurable modification at a time.",
    "Preferred voice: practical, concise, confidence-forward, and evidence-led. No fluff, no hype, no empty promises.",
    "For Marketing email prompts, always return templates using this structure:",
    "- Subject, Preview text, One clear opening line, One core value paragraph, CTA, and a brief footer line.",
    "- Keep every template aligned with current strategy history and avoid jargon or corporate fluff.",
    "Structure the response as: Direct answer; Why; Recommended next action; What to validate next; Evidence used.",
    `Saved internal strategies context:\n${strategyDigest(strategyHistory)}`,
    `Founder question: ${question}`,
    `Current Tip with clarity campaign snapshot:\n${
      growthSnapshotContext(growthSnapshot)
    }`,
    "US evidence database:",
    evidenceContext(evidence),
    "Qualitative search and SERP signals (geography may be unknown):",
    searchSignalContext(searchSignals),
  ].join("\n\n");

  const result = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: Deno.env.get("OPENAI_US_STRATEGY_MODEL") || DEFAULT_MODEL,
      reasoning: { effort: "low" },
      max_output_tokens: 1_500,
      input: prompt,
    }),
    signal: AbortSignal.timeout(45_000),
  });

  const data = await result.json().catch(() => ({})) as OpenAIResponse;
  if (!result.ok) throw new Error(`openai_${result.status}`);
  return data;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method === "GET") {
    return Response.redirect(
      "https://tippos.github.io/tippos-market-intelligence-assistant/",
      302,
    );
  }
  if (req.method !== "POST") {
    return response({ error: "method_not_allowed" }, 405);
  }
  const authorizationFailure = await authorizeStrategyRequest(req);
  if (authorizationFailure) return authorizationFailure;
  try {
    const body = await req.json() as Record<string, unknown>;
    if (body.action === "history") {
      const { data, error } = await adminClient().rpc("mi_list_strategies", {
        p_limit: 100,
      });
      if (error) throw new Error("strategy_history_read_failed");
      return response({ ok: true, strategies: data ?? [] });
    }
    const apiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
    if (!apiKey) {
      return response({ error: "openai_credentials_missing" }, 503);
    }
    const question = typeof body.question === "string"
      ? body.question.trim()
      : "";
    if (!question || question.length > MAX_QUESTION_LENGTH) {
      return response({ error: "invalid_question" }, 400);
    }
    const client = adminClient();
    const [
      { data, error },
      { data: searchData, error: searchError },
      { data: strategyData },
      { data: growthData, error: growthError },
    ] = await Promise.all([
      client.rpc("mi_get_us_strategy_evidence"),
      client.rpc("mi_get_autocomplete_search_signals"),
      client.rpc("mi_list_strategies", { p_limit: 30 }),
      client.rpc("mi_get_growth_campaign_snapshot", {}),
    ]);
    if (error || searchError) throw new Error("evidence_read_failed");
    if (growthError) {
      console.warn(
        "[market-intelligence-us-strategy] growth_snapshot_unavailable",
      );
    }
    const strategyHistory = Array.isArray(strategyData)
      ? strategyData as SavedStrategy[]
      : [];
    const evidence = (data ?? []) as Evidence[];
    const searchSignals = (searchData ?? []) as SearchSignal[];
    const growthSnapshot =
      !growthError && growthData && typeof growthData === "object"
        ? growthData as GrowthSnapshot
        : null;
    if (evidence.length === 0) {
      return response({ error: "us_evidence_unavailable" }, 503);
    }
    const model = Deno.env.get("OPENAI_US_STRATEGY_MODEL") || DEFAULT_MODEL;
    const answer = extractOutputText(
      await askOpenAIWithHistory(
        apiKey,
        question,
        evidence,
        searchSignals,
        strategyHistory,
        growthSnapshot,
      ),
    );
    if (!answer) throw new Error("openai_empty_response");
    const evidenceSnapshot = [
      ...evidence.map((
        {
          evidence_key,
          publisher,
          source_title,
          source_url,
          published_on,
          confidence,
        },
      ) => ({
        evidence_key,
        publisher,
        source_title,
        source_url,
        published_on,
        confidence,
      })),
      ...searchSignals.map((
        {
          query_text,
          use_case,
          industry,
          observed_on,
          country_code,
          source_key,
          confidence,
          interpretation,
        },
      ) => ({
        query_text,
        use_case,
        industry,
        observed_on,
        country_code,
        source_key,
        confidence,
        interpretation,
      })),
      { growth_campaign_snapshot: growthSnapshot },
    ];
    const { data: strategyId, error: saveError } = await adminClient().rpc(
      "mi_save_strategy",
      {
        p_question: question,
        p_answer: answer,
        p_model: model,
        p_evidence_snapshot: evidenceSnapshot,
      },
    );
    if (saveError) throw new Error("strategy_history_save_failed");
    return response({
      ok: true,
      id: strategyId,
      scope:
        "US strategy with qualitative search signals and aggregate campaign performance",
      question,
      answer,
      evidence: evidenceSnapshot,
      search_signals: searchSignals,
      growth_campaign: growthSnapshot,
      created_at: new Date().toISOString(),
      limitations: [
        "Autocomplete suggestions and manual SERP captures are qualitative, context-specific signals—not search volume, universal rank, geography, or growth data.",
        "Search Console and consented analytics can be incomplete or delayed; total market keyword volume and competitor traffic are not available.",
        "Recommendations are evidence-backed hypotheses until an experiment validates them.",
      ],
    });
  } catch (error) {
    console.error(
      "[market-intelligence-us-strategy] request_failed",
      error instanceof Error ? error.message : "unknown",
    );
    return response({ error: "strategy_request_failed" }, 400);
  }
});
