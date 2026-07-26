import type { SearchObservation } from "./market_intelligence.ts";

export type GoogleAdsMonthlySearchVolume = {
  year?: unknown;
  month?: unknown;
  monthlySearches?: unknown;
};

export type GoogleAdsHistoricalMetricsResult = {
  text?: unknown;
  closeVariants?: unknown;
  keywordMetrics?: {
    avgMonthlySearches?: unknown;
    monthlySearchVolumes?: unknown;
    competition?: unknown;
    competitionIndex?: unknown;
    averageCpcMicros?: unknown;
    lowTopOfPageBidMicros?: unknown;
    highTopOfPageBidMicros?: unknown;
  };
};

export type GoogleAdsKeywordIdeaResult = {
  text?: unknown;
};

export const GOOGLE_ADS_MAX_KEYWORD_SEEDS = 20;
export const GOOGLE_ADS_MAX_REVIEWED_KEYWORDS = 1_000;
export const GOOGLE_ADS_IMPORT_BATCH_SIZE = 1_000;

export const DEFAULT_GOOGLE_ADS_KEYWORD_SEEDS = [
  "tip calculator",
  "tip calculator per person",
  "split tip calculator",
  "tip calculator split bill",
  "how to split a tip",
  "restaurant bill split calculator",
  "tipping etiquette",
  "how much to tip",
  "digital tipping",
  "cashless tipping",
  "hotel tipping",
  "how much to tip housekeeping",
  "restaurant tipping",
  "how much to tip valet",
  "spa tipping",
];

const GOOGLE_ADS_MONTHS: Record<string, string> = {
  JANUARY: "01",
  FEBRUARY: "02",
  MARCH: "03",
  APRIL: "04",
  MAY: "05",
  JUNE: "06",
  JULY: "07",
  AUGUST: "08",
  SEPTEMBER: "09",
  OCTOBER: "10",
  NOVEMBER: "11",
  DECEMBER: "12",
};

function optionalFiniteNumber(value: unknown): number | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function optionalNonNegativeInteger(value: unknown): number | undefined {
  const parsed = optionalFiniteNumber(value);
  if (parsed === undefined || parsed < 0 || !Number.isSafeInteger(parsed)) {
    return undefined;
  }
  return parsed;
}

function microsToCurrency(value: unknown): number | undefined {
  const micros = optionalFiniteNumber(value);
  if (micros === undefined || micros < 0) return undefined;
  return Math.round((micros / 1_000_000) * 10_000) / 10_000;
}

function normalizeCloseVariants(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((variant) => {
    const normalized = typeof variant === "string"
      ? variant.trim().replace(/\s+/gu, " ")
      : "";
    return normalized && normalized.length <= 500 ? [normalized] : [];
  }).slice(0, 100);
}

function normalizeKeywordList(input: unknown, maxItems: number): string[] {
  if (!Array.isArray(input) || input.length < 1 || input.length > maxItems) {
    throw new Error("invalid_google_ads_keywords");
  }
  const deduplicated = new Map<string, string>();
  for (const value of input) {
    const keyword = typeof value === "string"
      ? value.trim().replace(/\s+/gu, " ")
      : "";
    if (!keyword || keyword.length > 80) {
      throw new Error("invalid_google_ads_keywords");
    }
    const key = keyword.toLocaleLowerCase("en-US");
    if (!deduplicated.has(key)) deduplicated.set(key, keyword);
  }
  return [...deduplicated.values()];
}

export function validateKeywordSeeds(input: unknown): string[] {
  return normalizeKeywordList(input, GOOGLE_ADS_MAX_KEYWORD_SEEDS);
}

export function validateReviewedKeywords(input: unknown): string[] {
  return normalizeKeywordList(input, GOOGLE_ADS_MAX_REVIEWED_KEYWORDS);
}

export function validateKeywordCandidateLimit(input: unknown): number {
  const parsed = typeof input === "number" ? input : Number(input);
  if (
    !Number.isSafeInteger(parsed) || parsed < 1 ||
    parsed > GOOGLE_ADS_MAX_REVIEWED_KEYWORDS
  ) {
    throw new Error("invalid_google_ads_keyword_limit");
  }
  return parsed;
}

export function mergeKeywordCandidates(
  seeds: string[],
  ideaRows: GoogleAdsKeywordIdeaResult[],
  limit: number,
): string[] {
  const deduplicated = new Map<string, string>();
  const add = (value: unknown) => {
    const keyword = typeof value === "string"
      ? value.trim().replace(/\s+/gu, " ")
      : "";
    if (!keyword || keyword.length > 80) return;
    const key = keyword.toLocaleLowerCase("en-US");
    if (!deduplicated.has(key)) deduplicated.set(key, keyword);
  };

  for (const seed of seeds) add(seed);
  for (const row of ideaRows) add(row.text);
  return [...deduplicated.values()].slice(0, limit);
}

function observationSortKey(observation: SearchObservation): string {
  return [
    observation.query.toLocaleLowerCase("en-US"),
    observation.observed_on,
    observation.granularity ?? "",
    observation.country_code ?? "",
    observation.device ?? "",
    JSON.stringify(observation),
  ].join("\u0000");
}

export function createObservationBatches(
  observations: SearchObservation[],
  batchSize = GOOGLE_ADS_IMPORT_BATCH_SIZE,
): SearchObservation[][] {
  if (!Number.isSafeInteger(batchSize) || batchSize < 1 || batchSize > 1_000) {
    throw new Error("invalid_google_ads_batch_size");
  }
  const sorted = [...observations].sort((left, right) =>
    observationSortKey(left).localeCompare(observationSortKey(right), "en-US")
  );
  const batches: SearchObservation[][] = [];
  for (let index = 0; index < sorted.length; index += batchSize) {
    batches.push(sorted.slice(index, index + batchSize));
  }
  return batches;
}

export async function createObservationBatchKey(
  requestKey: string,
  batch: SearchObservation[],
  batchNumber: number,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(JSON.stringify(batch)),
  );
  const hash = [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 16);
  return `${requestKey}-b${String(batchNumber).padStart(3, "0")}-${hash}`;
}

export function mapHistoricalKeywordMetrics(
  rows: GoogleAdsHistoricalMetricsResult[],
  languageCode: string,
  countryCode: string,
): SearchObservation[] {
  const observations: SearchObservation[] = [];

  for (const row of rows) {
    const query = typeof row.text === "string"
      ? row.text.trim().replace(/\s+/gu, " ")
      : "";
    if (!query || query.length > 500) continue;

    const metrics = row.keywordMetrics;
    const volumes = Array.isArray(metrics?.monthlySearchVolumes)
      ? metrics.monthlySearchVolumes as GoogleAdsMonthlySearchVolume[]
      : [];
    const averageMonthlySearches = optionalNonNegativeInteger(
      metrics?.avgMonthlySearches,
    );
    const competitionIndex = optionalFiniteNumber(metrics?.competitionIndex);
    const competition = competitionIndex === undefined
      ? undefined
      : Math.min(1, Math.max(0, competitionIndex / 100));
    const cpc = microsToCurrency(metrics?.averageCpcMicros);
    const closeVariants = normalizeCloseVariants(row.closeVariants);

    for (const volume of volumes) {
      const year = optionalNonNegativeInteger(volume.year);
      const month = typeof volume.month === "string"
        ? GOOGLE_ADS_MONTHS[volume.month.toUpperCase()]
        : undefined;
      const monthlySearches = optionalNonNegativeInteger(
        volume.monthlySearches,
      );
      if (
        year === undefined || year < 2000 || year > 2100 || !month ||
        monthlySearches === undefined
      ) {
        continue;
      }
      const observedOn = `${year}-${month}-01`;
      observations.push({
        query,
        language_code: languageCode,
        country_code: countryCode,
        observed_on: observedOn,
        event_at: `${observedOn}T00:00:00Z`,
        granularity: "month",
        search_volume: monthlySearches,
        cpc,
        competition,
        confidence: 0.8,
        intent: "unknown",
        funnel_stage: "awareness",
        source_metadata: {
          provider_metric: "approximate_monthly_searches",
          aggregation: "keyword_and_close_variants",
          average_monthly_searches: averageMonthlySearches,
          close_variants: closeVariants,
          competition_level: typeof metrics?.competition === "string"
            ? metrics.competition
            : undefined,
          competition_index: competitionIndex,
          average_cpc_micros: optionalNonNegativeInteger(
            metrics?.averageCpcMicros,
          ),
          low_top_of_page_bid_micros: optionalNonNegativeInteger(
            metrics?.lowTopOfPageBidMicros,
          ),
          high_top_of_page_bid_micros: optionalNonNegativeInteger(
            metrics?.highTopOfPageBidMicros,
          ),
        },
      });
    }
  }

  return observations;
}

function base64Url(data: Uint8Array | string): string {
  const bytes = typeof data === "string"
    ? new TextEncoder().encode(data)
    : data;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/g,
    "",
  );
}

export async function createGoogleAdsAssertion(
  clientEmail: string,
  privateKeyPem: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  if (!/^\S+@\S+$/.test(clientEmail)) {
    throw new Error("invalid_google_ads_client_email");
  }
  const clean = privateKeyPem.replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  if (!clean) throw new Error("invalid_google_ads_private_key");
  const der = Uint8Array.from(atob(clean), (char) => char.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = base64Url(JSON.stringify({
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/adwords",
    aud: "https://oauth2.googleapis.com/token",
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  }));
  const signingInput = `${header}.${claim}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

export async function fetchGoogleAdsAccessToken(
  clientEmail: string,
  privateKeyPem: string,
): Promise<string> {
  let assertion: string;
  try {
    assertion = await createGoogleAdsAssertion(clientEmail, privateKeyPem);
  } catch {
    throw new Error("google_ads_private_key_invalid");
  }
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
    signal: AbortSignal.timeout(20_000),
  });
  const data = await response.json().catch(() => ({})) as Record<
    string,
    unknown
  >;
  if (!response.ok || typeof data.access_token !== "string") {
    throw new Error(`google_ads_auth_${response.status}`);
  }
  return data.access_token;
}
