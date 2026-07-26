import {
  adminClient,
  hasBackendAccess,
  jsonResponse,
} from "../_shared/market_intelligence_runtime.ts";
import {
  createServiceAccountAssertion,
  finalizedSearchConsoleWindow,
  mapSearchConsoleRows,
  type SearchConsoleRow,
} from "../_shared/google_search_console.ts";
import { validateSearchObservations } from "../_shared/market_intelligence.ts";

const PAGE_SIZE = 25_000;
const MAX_ROWS = 50_000;

function validDate(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value) &&
    !Number.isNaN(Date.parse(`${value}T00:00:00Z`));
}

async function accessToken(
  clientEmail: string,
  privateKey: string,
): Promise<string> {
  const assertion = await createServiceAccountAssertion(
    clientEmail,
    privateKey,
  );
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
    throw new Error(`gsc_auth_${response.status}`);
  }
  return data.access_token;
}

async function queryPage(
  token: string,
  siteUrl: string,
  startDate: string,
  endDate: string,
  startRow: number,
): Promise<SearchConsoleRow[]> {
  const endpoint = `https://www.googleapis.com/webmasters/v3/sites/${
    encodeURIComponent(siteUrl)
  }/searchAnalytics/query`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      startDate,
      endDate,
      dimensions: ["date", "query", "device"],
      type: "web",
      dataState: "final",
      aggregationType: "byProperty",
      rowLimit: PAGE_SIZE,
      startRow,
    }),
    signal: AbortSignal.timeout(45_000),
  });
  const data = await response.json().catch(() => ({})) as Record<
    string,
    unknown
  >;
  if (!response.ok) throw new Error(`gsc_query_${response.status}`);
  return Array.isArray(data.rows) ? data.rows as SearchConsoleRow[] : [];
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }
  if (!(await hasBackendAccess(req))) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  const clientEmail = Deno.env.get("GSC_CLIENT_EMAIL") ?? "";
  const privateKey = Deno.env.get("GSC_PRIVATE_KEY") ?? "";
  const siteUrl = Deno.env.get("GSC_SITE_URL") ?? "";
  if (!clientEmail || !privateKey || !siteUrl) {
    return jsonResponse({ error: "gsc_credentials_missing" }, 503);
  }

  try {
    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    const requestKey = req.headers.get("idempotency-key")?.trim() ?? "";
    if (!/^[a-z0-9][a-z0-9_-]{7,119}$/.test(requestKey)) {
      return jsonResponse({ error: "invalid_idempotency_key" }, 400);
    }
    const automatic = body.automatic === true;
    const window = automatic
      ? finalizedSearchConsoleWindow()
      : { startDate: body.start_date, endDate: body.end_date };
    if (!validDate(window.startDate) || !validDate(window.endDate)) {
      return jsonResponse({ error: "invalid_date_range" }, 400);
    }
    const start = new Date(`${window.startDate}T00:00:00Z`);
    const end = new Date(`${window.endDate}T00:00:00Z`);
    const daySpan = Math.round((end.getTime() - start.getTime()) / 86_400_000);
    if (daySpan < 0 || daySpan > 31) {
      return jsonResponse({ error: "invalid_date_range" }, 400);
    }

    const token = await accessToken(clientEmail, privateKey);
    let offset = 0;
    let loaded = 0;
    let batchNumber = 0;
    while (offset < MAX_ROWS) {
      const rows = await queryPage(
        token,
        siteUrl,
        window.startDate,
        window.endDate,
        offset,
      );
      if (rows.length === 0) break;
      const mapped = validateSearchObservations(
        mapSearchConsoleRows(rows, offset),
      );
      for (let index = 0; index < mapped.length; index += 1000) {
        const batch = mapped.slice(index, index + 1000);
        const { error } = await adminClient().rpc("mi_import_search_metrics", {
          p_source_key: "google_search_console",
          p_external_job_key: `${requestKey}-b${batchNumber}`,
          p_observations: batch,
          p_dry_run: body.dry_run === true,
        });
        if (error) throw new Error("gsc_ingestion_failed");
        batchNumber += 1;
        loaded += batch.length;
      }
      offset += rows.length;
      if (rows.length < PAGE_SIZE) break;
    }
    return jsonResponse({
      ok: true,
      source: "google_search_console",
      period: { start_date: window.startDate, end_date: window.endDate },
      rows_loaded: loaded,
      batches: batchNumber,
      truncated: offset >= MAX_ROWS,
      automatic,
      dry_run: body.dry_run === true,
    });
  } catch (error) {
    const code = error instanceof Error && /^[a-z0-9_]+$/.test(error.message)
      ? error.message
      : "gsc_sync_failed";
    console.error("[market-intelligence-gsc-sync] sync_failed", code);
    const requestKey = req.headers.get("idempotency-key")?.trim() ??
      "gsc-unknown";
    try {
      const { error: recordError } = await adminClient().rpc(
        "mi_record_collection_failure",
        {
          p_source_key: "google_search_console",
          p_external_job_key: requestKey,
          p_error_code: code,
        },
      );
      if (recordError) {
        console.warn(
          "[market-intelligence-gsc-sync] failure_record_unavailable",
        );
      }
    } catch {
      console.warn("[market-intelligence-gsc-sync] failure_record_unavailable");
    }
    return jsonResponse({ error: code }, 400);
  }
});
