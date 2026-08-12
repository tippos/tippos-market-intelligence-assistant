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
import {
  isGoogleTrendsDatasetKind,
  parseGoogleTrendsComparisonCsv,
  parseGoogleTrendsCsv,
  sha256Hex,
} from "../_shared/google_trends.ts";

const DEFAULT_MODEL = "gpt-5.6-terra";
const MAX_QUESTION_LENGTH = 1_000;
const MAX_GOOGLE_TRENDS_CSV_CHARACTERS = 500_000;
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

function optionalIsoDate(value: unknown): string | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new Error("invalid_google_trends_period");
  }
  return value;
}

async function importGoogleTrendsLegacyExport(
  client: ReturnType<typeof adminClient>,
  body: Record<string, unknown>,
): Promise<Response> {
  const queryText = typeof body.query_text === "string"
    ? body.query_text.trim()
    : "";
  const datasetKind = body.dataset_kind;
  const csv = typeof body.csv === "string" ? body.csv : "";
  const countryCode = typeof body.country_code === "string"
    ? body.country_code.trim().toUpperCase()
    : "US";
  const category = typeof body.category === "string" ? body.category.trim() : "";
  const searchType = typeof body.search_type === "string"
    ? body.search_type.trim()
    : "";
  if (
    !queryText || queryText.length > 500 || countryCode !== "US" ||
    !isGoogleTrendsDatasetKind(datasetKind) || !csv ||
    csv.length > MAX_GOOGLE_TRENDS_CSV_CHARACTERS
  ) {
    return response({ error: "invalid_google_trends_import" }, 400);
  }

  try {
    const parsed = parseGoogleTrendsCsv(datasetKind, csv);
    const requestedStart = optionalIsoDate(body.period_start);
    const requestedEnd = optionalIsoDate(body.period_end);
    const observedDates = (parsed.interest_over_time ?? []).map((item) =>
      item.observed_on
    ).sort();
    const periodStart = observedDates[0] ?? requestedStart;
    const periodEnd = observedDates.at(-1) ?? requestedEnd;
    if (periodStart && periodEnd && periodStart > periodEnd) {
      return response({ error: "invalid_google_trends_period" }, 400);
    }
    const payload = {
      ...parsed,
      interest_over_time: parsed.interest_over_time ?? [],
      geo_metrics: parsed.geo_metrics ?? [],
      related_terms: parsed.related_terms ?? [],
    };
    const loaded = payload.interest_over_time.length + payload.geo_metrics.length +
      payload.related_terms.length;
    const { data, error } = await client.rpc("mi_import_google_trends_export", {
      p_query_text: queryText,
      p_country_code: countryCode,
      p_category: category || "All categories",
      p_search_type: searchType || "Web Search",
      p_period_start: periodStart,
      p_period_end: periodEnd,
      p_dataset_kind: datasetKind,
      p_file_checksum: await sha256Hex(csv),
      p_metadata: {
        imported_via: "private_strategy_assistant",
        parser: "google_trends_manual_csv_v1",
        parsed_row_count: loaded,
      },
      p_payload: payload,
    });
    if (error) {
      console.error(
        "[market-intelligence-us-strategy] google_trends_import_failed",
        error.message,
      );
      return response({ error: "google_trends_import_failed" }, 400);
    }
    return response({ ok: true, google_trends_import: data });
  } catch (error) {
    console.warn(
      "[market-intelligence-us-strategy] invalid_google_trends_csv",
      error instanceof Error ? error.message : "unknown",
    );
    return response({ error: "invalid_google_trends_csv" }, 400);
  }
}

async function importGoogleTrendsComparisonExport(
  client: ReturnType<typeof adminClient>,
  body: Record<string, unknown>,
): Promise<Response> {
  const queryText = typeof body.query_text === "string"
    ? body.query_text.trim()
    : "";
  const datasetKind = body.dataset_kind;
  const csv = typeof body.csv === "string" ? body.csv : "";
  const countryCode = typeof body.country_code === "string"
    ? body.country_code.trim().toUpperCase()
    : "US";
  const category = typeof body.category === "string" ? body.category.trim() : "";
  const searchType = typeof body.search_type === "string"
    ? body.search_type.trim()
    : "";
  const isComparisonDataset = datasetKind === "interest_over_time" ||
    datasetKind === "interest_by_subregion";
  if (
    queryText.length > 500 || countryCode !== "US" ||
    !isGoogleTrendsDatasetKind(datasetKind) || !csv ||
    (!isComparisonDataset && !queryText) ||
    csv.length > MAX_GOOGLE_TRENDS_CSV_CHARACTERS
  ) {
    return response({ error: "invalid_google_trends_import" }, 400);
  }
  try {
    const requestedStart = optionalIsoDate(body.period_start);
    const requestedEnd = optionalIsoDate(body.period_end);
    const parsedSeries = isComparisonDataset
      ? parseGoogleTrendsComparisonCsv(datasetKind, csv)
      : [{
        ...parseGoogleTrendsCsv(datasetKind, csv),
        query_text: queryText,
        series_key: "single",
        metric_interpretation:
          "relative_interest_index_0_100_not_search_volume" as const,
      }];
    const sourceFileChecksum = await sha256Hex(csv);
    const comparisonTerms = parsedSeries.map((series) => series.query_text);
    const imports: unknown[] = [];
    let loaded = 0;
    for (const series of parsedSeries) {
      const observedDates = (series.interest_over_time ?? []).map((item) =>
        item.observed_on
      ).sort();
      const periodStart = observedDates[0] ?? requestedStart;
      const periodEnd = observedDates.at(-1) ?? requestedEnd;
      if (periodStart && periodEnd && periodStart > periodEnd) {
        return response({ error: "invalid_google_trends_period" }, 400);
      }
      const payload = {
        interest_over_time: series.interest_over_time ?? [],
        geo_metrics: series.geo_metrics ?? [],
        related_terms: series.related_terms ?? [],
      };
      const seriesLoaded = payload.interest_over_time.length +
        payload.geo_metrics.length + payload.related_terms.length;
      const { data, error } = await client.rpc("mi_import_google_trends_export", {
        p_query_text: series.query_text,
        p_country_code: countryCode,
        p_category: category || "All categories",
        p_search_type: searchType || "Web Search",
        p_period_start: periodStart,
        p_period_end: periodEnd,
        p_dataset_kind: datasetKind,
        p_file_checksum: sourceFileChecksum,
        p_metadata: {
          imported_via: "private_strategy_assistant",
          parser: "google_trends_manual_csv_v2",
          parsed_row_count: seriesLoaded,
          series_key: series.series_key,
          comparison_series_count: parsedSeries.length,
          comparison_terms: comparisonTerms,
          metric_interpretation: series.metric_interpretation,
        },
        p_payload: payload,
      });
      if (error) {
        console.error(
          "[market-intelligence-us-strategy] google_trends_import_failed",
          error.message,
        );
        return response({ error: "google_trends_import_failed" }, 400);
      }
      imports.push(data);
      loaded += seriesLoaded;
    }
    return response({
      ok: true,
      google_trends_import: {
        loaded,
        imported_series: imports.length,
        comparison: imports.length > 1,
        imports,
      },
    });
  } catch (error) {
    console.warn(
      "[market-intelligence-us-strategy] invalid_google_trends_csv",
      error instanceof Error ? error.message : "unknown",
    );
    return response({ error: "invalid_google_trends_csv" }, 400);
  }
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
    "Google Trends manual exports provide a relative 0-100 interest index and related terms only within the exact exported query, geography, period, category, and search type. They are not search volume, market size, or comparable across unrelated exports.",
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
  googleTrendsEvidence: Evidence[],
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
    "Google Trends manual exports provide a relative 0-100 interest index and related terms only within the exact exported query, geography, period, category, and search type. They are not search volume, market size, or comparable across unrelated exports.",
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
    "Google Trends manual relative-interest signals (only when imported):",
    evidenceContext(googleTrendsEvidence),
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
    if (body.action === "import_google_trends") {
      return await importGoogleTrendsComparisonExport(adminClient(), body);
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
      { data: googleTrendsData, error: googleTrendsError },
      { data: strategyData },
      { data: growthData, error: growthError },
    ] = await Promise.all([
      client.rpc("mi_get_us_strategy_evidence"),
      client.rpc("mi_get_autocomplete_search_signals"),
      client.rpc("mi_get_us_strategy_google_trends_evidence"),
      client.rpc("mi_list_strategies", { p_limit: 30 }),
      client.rpc("mi_get_growth_campaign_snapshot", {}),
    ]);
    if (error || searchError) throw new Error("evidence_read_failed");
    if (googleTrendsError) {
      console.warn(
        "[market-intelligence-us-strategy] google_trends_evidence_unavailable",
      );
    }
    if (growthError) {
      console.warn(
        "[market-intelligence-us-strategy] growth_snapshot_unavailable",
      );
    }
    const strategyHistory = Array.isArray(strategyData)
      ? strategyData as SavedStrategy[]
      : [];
    const evidence = (data ?? []) as Evidence[];
    const googleTrendsEvidence = googleTrendsError
      ? []
      : (googleTrendsData ?? []) as Evidence[];
    const combinedEvidence = [...evidence, ...googleTrendsEvidence];
    const searchSignals = (searchData ?? []) as SearchSignal[];
    const growthSnapshot =
      !growthError && growthData && typeof growthData === "object"
        ? growthData as GrowthSnapshot
        : null;
    if (combinedEvidence.length === 0) {
      return response({ error: "us_evidence_unavailable" }, 503);
    }
    const model = Deno.env.get("OPENAI_US_STRATEGY_MODEL") || DEFAULT_MODEL;
    const answer = extractOutputText(
      await askOpenAIWithHistory(
        apiKey,
        question,
        evidence,
        searchSignals,
        googleTrendsEvidence,
        strategyHistory,
        growthSnapshot,
      ),
    );
    if (!answer) throw new Error("openai_empty_response");
    const evidenceSnapshot = [
      ...combinedEvidence.map((
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
        "US strategy with cited market evidence, imported Google Trends signals, qualitative search signals, and aggregate campaign performance",
      question,
      answer,
      evidence: evidenceSnapshot,
      search_signals: searchSignals,
      growth_campaign: growthSnapshot,
      created_at: new Date().toISOString(),
      limitations: [
        "Google Trends values are relative 0-100 indexes and related-term signals from the exact manually imported export—not search volume, market size, or comparable across unrelated exports.",
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
