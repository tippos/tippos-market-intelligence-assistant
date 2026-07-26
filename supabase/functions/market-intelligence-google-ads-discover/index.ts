import {
  hasBackendAccess,
  jsonResponse,
} from "../_shared/market_intelligence_runtime.ts";
import {
  DEFAULT_GOOGLE_ADS_KEYWORD_SEEDS,
  fetchGoogleAdsAccessToken,
  type GoogleAdsKeywordIdeaResult,
  mergeKeywordCandidates,
  validateKeywordCandidateLimit,
  validateKeywordSeeds,
} from "../_shared/google_ads_keyword_planner.ts";

const GOOGLE_ADS_API_VERSION = "v25";
const GOOGLE_ADS_LANGUAGE = "languageConstants/1000";
const GOOGLE_ADS_US_GEO_TARGET = "geoTargetConstants/2840";
const DEFAULT_CANDIDATE_LIMIT = 1_000;
const MAX_IDEA_PAGES = 10;
const GOOGLE_ADS_REQUEST_SPACING_MS = 1_050;

function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }
  if (!(await hasBackendAccess(req))) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }

  const email = Deno.env.get("GOOGLE_ADS_CLIENT_EMAIL") ?? "";
  const privateKey = Deno.env.get("GOOGLE_ADS_PRIVATE_KEY") ?? "";
  const developerToken = Deno.env.get("GOOGLE_ADS_DEVELOPER_TOKEN") ?? "";
  const loginCustomerId = (Deno.env.get("GOOGLE_ADS_LOGIN_CUSTOMER_ID") ?? "")
    .replace(/\D/g, "");
  const customerId = (Deno.env.get("GOOGLE_ADS_CUSTOMER_ID") ?? "")
    .replace(/\D/g, "");
  if (
    !email || !privateKey || !developerToken || !/^\d{10}$/.test(customerId) ||
    (loginCustomerId && !/^\d{10}$/.test(loginCustomerId))
  ) {
    return jsonResponse({ error: "google_ads_credentials_missing" }, 503);
  }

  try {
    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    const seeds = validateKeywordSeeds(
      body.seed_keywords ?? DEFAULT_GOOGLE_ADS_KEYWORD_SEEDS,
    );
    const candidateLimit = validateKeywordCandidateLimit(
      body.max_keywords ?? DEFAULT_CANDIDATE_LIMIT,
    );
    const token = await fetchGoogleAdsAccessToken(email, privateKey);
    const headers: Record<string, string> = {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "developer-token": developerToken,
    };
    if (loginCustomerId) headers["login-customer-id"] = loginCustomerId;

    const ideaRows: GoogleAdsKeywordIdeaResult[] = [];
    let nextPageToken = "";
    let pagesFetched = 0;
    let lastRequestAt = 0;

    while (pagesFetched < MAX_IDEA_PAGES) {
      const elapsed = Date.now() - lastRequestAt;
      if (lastRequestAt > 0 && elapsed < GOOGLE_ADS_REQUEST_SPACING_MS) {
        await wait(GOOGLE_ADS_REQUEST_SPACING_MS - elapsed);
      }
      const requestBody: Record<string, unknown> = {
        language: GOOGLE_ADS_LANGUAGE,
        geoTargetConstants: [GOOGLE_ADS_US_GEO_TARGET],
        includeAdultKeywords: false,
        keywordPlanNetwork: "GOOGLE_SEARCH",
        keywordSeed: { keywords: seeds },
        pageSize: candidateLimit,
      };
      if (nextPageToken) requestBody.pageToken = nextPageToken;

      lastRequestAt = Date.now();
      const response = await fetch(
        `https://googleads.googleapis.com/${GOOGLE_ADS_API_VERSION}/customers/${customerId}:generateKeywordIdeas`,
        {
          method: "POST",
          headers,
          body: JSON.stringify(requestBody),
          signal: AbortSignal.timeout(45_000),
        },
      );
      const data = await response.json().catch(() => ({})) as Record<
        string,
        unknown
      >;
      if (!response.ok) throw new Error(`google_ads_ideas_${response.status}`);

      pagesFetched += 1;
      if (Array.isArray(data.results)) {
        ideaRows.push(...data.results as GoogleAdsKeywordIdeaResult[]);
      }
      nextPageToken = typeof data.nextPageToken === "string"
        ? data.nextPageToken
        : "";
      const candidates = mergeKeywordCandidates(
        seeds,
        ideaRows,
        candidateLimit,
      );
      if (candidates.length >= candidateLimit || !nextPageToken) break;
    }

    const candidates = mergeKeywordCandidates(seeds, ideaRows, candidateLimit);
    return jsonResponse({
      ok: true,
      source: "google_ads_keyword_ideas",
      evidence_status: "candidate_only_not_measured",
      evidence_landed: false,
      review_required: true,
      scope: {
        country_code: "US",
        language_code: "en",
        network: "GOOGLE_SEARCH",
      },
      seed_keywords: seeds,
      candidate_count: candidates.length,
      candidates,
      pages_fetched: pagesFetched,
      more_provider_results_available: Boolean(nextPageToken),
      limitations: [
        "Keyword ideas are candidates, not measured evidence.",
        "Only reviewed candidates may be sent to historical metrics ingestion.",
        "No keyword-idea metrics are stored by this function.",
      ],
    });
  } catch (error) {
    const code = error instanceof Error && /^[a-z0-9_]+$/.test(error.message)
      ? error.message
      : "google_ads_discovery_failed";
    console.error("[market-intelligence-google-ads-discover] discovery_failed", code);
    return jsonResponse({ error: code }, 400);
  }
});
