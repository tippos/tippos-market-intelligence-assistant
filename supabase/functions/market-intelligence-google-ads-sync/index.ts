import {
  adminClient,
  hasBackendAccess,
  jsonResponse,
} from "../_shared/market_intelligence_runtime.ts";
import {
  createObservationBatchKey,
  createObservationBatches,
  DEFAULT_GOOGLE_ADS_KEYWORD_SEEDS,
  fetchGoogleAdsAccessToken,
  type GoogleAdsHistoricalMetricsResult,
  mapHistoricalKeywordMetrics,
  validateReviewedKeywords,
} from "../_shared/google_ads_keyword_planner.ts";
import {
  type SearchObservation,
  validateSearchObservations,
} from "../_shared/market_intelligence.ts";

const GOOGLE_ADS_API_VERSION = "v25";
const GOOGLE_ADS_LANGUAGE = "languageConstants/1000";
const GOOGLE_ADS_US_GEO_TARGET = "geoTargetConstants/2840";

type BatchImportSummary = {
  batch_count: number;
  replayed_batches: number;
  rows_loaded: number;
  results: Record<string, unknown>[];
};

async function importObservationBatches(
  requestKey: string,
  observations: SearchObservation[],
  dryRun: boolean,
): Promise<BatchImportSummary> {
  const batches = createObservationBatches(observations);
  let replayedBatches = 0;
  let rowsLoaded = 0;
  const results: Record<string, unknown>[] = [];

  for (let index = 0; index < batches.length; index += 1) {
    const batch = validateSearchObservations(batches[index]);
    const batchKey = await createObservationBatchKey(
      requestKey,
      batch,
      index + 1,
    );
    const { data, error } = await adminClient().rpc(
      "mi_import_search_metrics",
      {
        p_source_key: "google_ads_keyword_planner",
        p_external_job_key: batchKey,
        p_observations: batch,
        p_dry_run: dryRun,
      },
    );
    if (error) throw new Error("google_ads_ingestion_failed");
    const summary = data && typeof data === "object" && !Array.isArray(data)
      ? data as Record<string, unknown>
      : {};
    results.push(summary);
    if (summary.replayed === true) {
      replayedBatches += 1;
    } else if (!dryRun && typeof summary.loaded === "number") {
      rowsLoaded += summary.loaded;
    }
  }

  return {
    batch_count: batches.length,
    replayed_batches: replayedBatches,
    rows_loaded: rowsLoaded,
    results,
  };
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

  const requestKey = req.headers.get("idempotency-key")?.trim() ?? "";
  if (!/^[a-z0-9][a-z0-9_-]{7,119}$/.test(requestKey)) {
    return jsonResponse({ error: "invalid_idempotency_key" }, 400);
  }

  try {
    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    const keywords = validateReviewedKeywords(
      body.keywords ?? DEFAULT_GOOGLE_ADS_KEYWORD_SEEDS,
    );
    const token = await fetchGoogleAdsAccessToken(email, privateKey);
    const headers: Record<string, string> = {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "developer-token": developerToken,
    };
    if (loginCustomerId) headers["login-customer-id"] = loginCustomerId;

    const response = await fetch(
      `https://googleads.googleapis.com/${GOOGLE_ADS_API_VERSION}/customers/${customerId}:generateKeywordHistoricalMetrics`,
      {
        method: "POST",
        headers,
        body: JSON.stringify({
          keywords,
          language: GOOGLE_ADS_LANGUAGE,
          geoTargetConstants: [GOOGLE_ADS_US_GEO_TARGET],
          includeAdultKeywords: false,
          keywordPlanNetwork: "GOOGLE_SEARCH",
          historicalMetricsOptions: { includeAverageCpc: true },
        }),
        signal: AbortSignal.timeout(45_000),
      },
    );
    const data = await response.json().catch(() => ({})) as Record<
      string,
      unknown
    >;
    if (!response.ok) throw new Error(`google_ads_query_${response.status}`);

    const historicalResults = Array.isArray(data.results)
      ? data.results as GoogleAdsHistoricalMetricsResult[]
      : [];
    const observations = mapHistoricalKeywordMetrics(
      historicalResults,
      "en",
      "US",
    );
    if (observations.length === 0) throw new Error("google_ads_no_metrics");
    const dryRun = body.dry_run === true;
    const importSummary = await importObservationBatches(
      requestKey,
      observations,
      dryRun,
    );

    return jsonResponse({
      ok: true,
      source: "google_ads_keyword_planner",
      metric: "approximate_monthly_searches",
      scope: {
        country_code: "US",
        language_code: "en",
        network: "GOOGLE_SEARCH",
      },
      requested_keywords: keywords.length,
      returned_metric_keywords: historicalResults.length,
      rows_seen: observations.length,
      rows_loaded: importSummary.rows_loaded,
      evidence_landed: !dryRun && importSummary.rows_loaded > 0,
      batch_count: importSummary.batch_count,
      replayed_batches: importSummary.replayed_batches,
      dry_run: dryRun,
      import_results: importSummary.results,
      limitations: [
        "Search counts are approximate, not unique people.",
        "Google may aggregate close keyword variants.",
        "Near-exact deduplication can return fewer rows than requested keywords.",
        "Historical metrics refresh monthly.",
      ],
    });
  } catch (error) {
    const code = error instanceof Error && /^[a-z0-9_]+$/.test(error.message)
      ? error.message
      : "google_ads_sync_failed";
    console.error("[market-intelligence-google-ads-sync] sync_failed", code);
    try {
      await adminClient().rpc("mi_record_collection_failure", {
        p_source_key: "google_ads_keyword_planner",
        p_external_job_key: requestKey,
        p_error_code: code,
      });
    } catch {
      // Preserve the provider error even if failure logging is unavailable.
    }
    return jsonResponse({ error: code }, 400);
  }
});
