export type SearchObservation = {
  query: string;
  language_code: string;
  country_code?: string;
  observed_on: string;
  event_at?: string;
  granularity?: "day" | "week" | "month";
  device?: "desktop" | "mobile" | "tablet" | "other";
  impressions?: number;
  clicks?: number;
  search_volume?: number;
  ctr?: number;
  average_position?: number;
  cpc?: number;
  competition?: number;
  trend_score?: number;
  confidence?: number;
  intent?:
    | "informational"
    | "commercial"
    | "transactional"
    | "navigational"
    | "local"
    | "unknown";
  funnel_stage?:
    | "awareness"
    | "consideration"
    | "conversion"
    | "retention"
    | "unknown";
  persona?: string;
  industry?: string;
  use_case?: string;
  is_branded?: boolean;
  business_relevance?: number;
  external_id?: string;
  source_metadata?: Record<string, unknown>;
};

export type AiVisibilityPayload = {
  source_key: string;
  prompt_key: string;
  provider_model: string;
  status: "succeeded" | "failed" | "blocked_policy";
  response_summary: Record<string, unknown>;
  response_text?: string;
  retention_mode: "full" | "summary" | "metadata_only";
  mentions: Array<Record<string, unknown>>;
  citations: Array<Record<string, unknown>>;
  metrics?: Record<string, unknown>;
};

const LANGUAGE_RE =
  /^[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-(?:[A-Z]{2}|[0-9]{3}))?$/;
const COUNTRY_RE = /^[A-Z]{2}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const SAFE_KEY_RE = /^[a-z0-9][a-z0-9_-]{1,199}$/;

function optionalNumber(
  value: unknown,
  name: string,
  min: number,
  max = Number.MAX_SAFE_INTEGER,
): number | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed) || parsed < min || parsed > max) {
    throw new Error(`invalid_${name}`);
  }
  return parsed;
}

function optionalText(value: unknown, max: number): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  if (typeof value !== "string" || value.length > max) {
    throw new Error("invalid_text_field");
  }
  return value;
}

function optionalMetadata(value: unknown): Record<string, unknown> | undefined {
  if (value === undefined || value === null) return undefined;
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("invalid_source_metadata");
  }
  const serialized = JSON.stringify(value);
  if (serialized.length > 10_000) throw new Error("invalid_source_metadata");
  return value as Record<string, unknown>;
}

export function validateSearchObservations(
  input: unknown,
): SearchObservation[] {
  if (!Array.isArray(input) || input.length === 0 || input.length > 1000) {
    throw new Error("invalid_observations_batch");
  }
  return input.map((raw) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
      throw new Error("invalid_search_observation");
    }
    const item = raw as Record<string, unknown>;
    const query = typeof item.query === "string"
      ? item.query.trim().replace(/\s+/gu, " ")
      : "";
    const language = typeof item.language_code === "string"
      ? item.language_code
      : "";
    const country = typeof item.country_code === "string" && item.country_code
      ? item.country_code.toUpperCase()
      : undefined;
    const observedOn = typeof item.observed_on === "string"
      ? item.observed_on
      : "";
    if (
      !query || query.length > 500 || !LANGUAGE_RE.test(language) ||
      !DATE_RE.test(observedOn)
    ) {
      throw new Error("invalid_search_observation");
    }
    if (country && !COUNTRY_RE.test(country)) {
      throw new Error("invalid_country_code");
    }
    const result: SearchObservation = {
      query,
      language_code: language,
      observed_on: observedOn,
      country_code: country,
    };
    const granularity = item.granularity ?? "day";
    if (!["day", "week", "month"].includes(String(granularity))) {
      throw new Error("invalid_granularity");
    }
    result.granularity = granularity as SearchObservation["granularity"];
    if (
      item.device !== undefined &&
      !["desktop", "mobile", "tablet", "other"].includes(String(item.device))
    ) {
      throw new Error("invalid_device");
    }
    result.device = item.device as SearchObservation["device"];
    result.impressions = optionalNumber(item.impressions, "impressions", 0);
    result.clicks = optionalNumber(item.clicks, "clicks", 0);
    result.search_volume = optionalNumber(
      item.search_volume,
      "search_volume",
      0,
    );
    result.ctr = optionalNumber(item.ctr, "ctr", 0, 1);
    result.average_position = optionalNumber(
      item.average_position,
      "average_position",
      0,
    );
    result.cpc = optionalNumber(item.cpc, "cpc", 0);
    result.competition = optionalNumber(item.competition, "competition", 0, 1);
    result.trend_score = optionalNumber(
      item.trend_score,
      "trend_score",
      -100,
      100,
    );
    result.confidence = optionalNumber(item.confidence, "confidence", 0, 1);
    result.business_relevance = optionalNumber(
      item.business_relevance,
      "business_relevance",
      0,
      100,
    );
    result.event_at = optionalText(item.event_at, 40);
    result.persona = optionalText(item.persona, 100);
    result.industry = optionalText(item.industry, 100);
    result.use_case = optionalText(item.use_case, 100);
    result.external_id = optionalText(item.external_id, 200);
    result.source_metadata = optionalMetadata(item.source_metadata);
    if (item.is_branded !== undefined && typeof item.is_branded !== "boolean") {
      throw new Error("invalid_is_branded");
    }
    result.is_branded = item.is_branded as boolean | undefined;
    const intent = item.intent ?? "unknown";
    if (
      ![
        "informational",
        "commercial",
        "transactional",
        "navigational",
        "local",
        "unknown",
      ].includes(String(intent))
    ) {
      throw new Error("invalid_intent");
    }
    result.intent = intent as SearchObservation["intent"];
    const funnel = item.funnel_stage ?? "unknown";
    if (
      !["awareness", "consideration", "conversion", "retention", "unknown"]
        .includes(String(funnel))
    ) {
      throw new Error("invalid_funnel_stage");
    }
    result.funnel_stage = funnel as SearchObservation["funnel_stage"];
    return Object.fromEntries(
      Object.entries(result).filter(([, value]) => value !== undefined),
    ) as SearchObservation;
  });
}

export function validateAiVisibilityPayload(
  input: unknown,
): AiVisibilityPayload {
  if (!input || typeof input !== "object" || Array.isArray(input)) {
    throw new Error("invalid_ai_visibility_payload");
  }
  const value = input as Record<string, unknown>;
  const requiredKeys = [
    "source_key",
    "prompt_key",
    "provider_model",
    "status",
    "response_summary",
    "retention_mode",
    "mentions",
    "citations",
  ];
  if (requiredKeys.some((key) => value[key] === undefined)) {
    throw new Error("invalid_ai_visibility_payload");
  }
  if (
    !SAFE_KEY_RE.test(String(value.source_key)) ||
    !SAFE_KEY_RE.test(String(value.prompt_key))
  ) throw new Error("invalid_ai_key");
  if (
    typeof value.provider_model !== "string" ||
    value.provider_model.length < 2 || value.provider_model.length > 200
  ) throw new Error("invalid_provider_model");
  if (
    !["succeeded", "failed", "blocked_policy"].includes(String(value.status))
  ) throw new Error("invalid_ai_status");
  if (
    !["full", "summary", "metadata_only"].includes(String(value.retention_mode))
  ) throw new Error("invalid_retention_mode");
  if (value.retention_mode !== "full" && value.response_text !== undefined) {
    throw new Error("response_text_not_allowed");
  }
  if (
    !value.response_summary || typeof value.response_summary !== "object" ||
    Array.isArray(value.response_summary)
  ) throw new Error("invalid_response_summary");
  if (!Array.isArray(value.mentions) || value.mentions.length > 100) {
    throw new Error("invalid_mentions");
  }
  if (!Array.isArray(value.citations) || value.citations.length > 100) {
    throw new Error("invalid_citations");
  }
  for (const mention of value.mentions as Array<Record<string, unknown>>) {
    if (
      !mention || typeof mention !== "object" ||
      typeof mention.brand_key !== "string" || !mention.brand_key.trim() ||
      mention.brand_key.length > 100
    ) throw new Error("invalid_ai_mention");
    optionalNumber(mention.position, "mention_position", 1, 1000);
    optionalNumber(mention.sentiment, "sentiment", -1, 1);
    optionalNumber(
      mention.recommendation_strength,
      "recommendation_strength",
      0,
      1,
    );
    optionalNumber(mention.confidence, "mention_confidence", 0, 1);
  }
  for (const citation of value.citations as Array<Record<string, unknown>>) {
    if (
      !citation || typeof citation !== "object" ||
      typeof citation.url !== "string" || citation.url.length > 2048
    ) throw new Error("invalid_ai_citation");
    const url = new URL(citation.url);
    if (!["http:", "https:"].includes(url.protocol)) {
      throw new Error("invalid_ai_citation");
    }
    if (
      optionalNumber(citation.order, "citation_order", 1, 1000) === undefined
    ) throw new Error("invalid_citation_order");
  }
  return value as unknown as AiVisibilityPayload;
}

export function parseCsv(input: string): Array<Record<string, string>> {
  if (input.length > 1_000_000) throw new Error("csv_too_large");
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < input.length; i += 1) {
    const char = input[i];
    if (char === '"') {
      if (quoted && input[i + 1] === '"') {
        cell += '"';
        i += 1;
      } else quoted = !quoted;
    } else if (char === "," && !quoted) {
      row.push(cell);
      cell = "";
    } else if ((char === "\n" || char === "\r") && !quoted) {
      if (char === "\r" && input[i + 1] === "\n") i += 1;
      row.push(cell);
      cell = "";
      if (row.some((value) => value.length > 0)) rows.push(row);
      row = [];
    } else {
      cell += char;
    }
  }
  if (quoted) throw new Error("unterminated_csv_quote");
  row.push(cell);
  if (row.some((value) => value.length > 0)) rows.push(row);
  if (rows.length < 2) throw new Error("csv_requires_header_and_data");
  const headers = rows[0].map((header) =>
    header.trim().replace(/^\uFEFF/u, "")
  );
  if (
    new Set(headers).size !== headers.length ||
    headers.some((header) => !header)
  ) throw new Error("invalid_csv_headers");
  if (
    !headers.includes("query") || !headers.includes("language_code") ||
    !headers.includes("observed_on")
  ) throw new Error("missing_csv_headers");
  return rows.slice(1).map((values) =>
    Object.fromEntries(
      headers.map((header, index) => [header, values[index] ?? ""]),
    )
  );
}
