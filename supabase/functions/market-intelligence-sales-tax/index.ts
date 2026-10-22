// Supabase Edge Function: market-intelligence-sales-tax
//
// Live U.S. sales-tax rates for the brand site's tax-and-tip calculator
// (/tip-calculator/tax and the state pages).
//
// GET  (public, no key): the stored rates, newest edition, as JSON. The site
//      fetches this in the browser and falls back to its own built-in rates
//      if the call fails.
// POST (backend key only, sent by the monthly cron): finds the newest Tax
//      Foundation table, parses it, checks it (sales_tax.ts) and stores it.
//      A table that fails any check is not stored; the old rates stay.
//
// verify_jwt is off because GET is public; POST checks the key itself.

import { adminClient, hasBackendAccess, jsonResponse } from "../_shared/market_intelligence_runtime.ts";
import {
  candidateEditions,
  checkSalesTaxRows,
  parseSalesTaxTable,
  type SalesTaxEdition,
  type SalesTaxRow,
} from "../_shared/sales_tax.ts";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function withCors(res: Response, extra: Record<string, string> = {}): Response {
  const headers = new Headers(res.headers);
  for (const [k, v] of Object.entries({ ...CORS_HEADERS, ...extra })) headers.set(k, v);
  return new Response(res.body, { status: res.status, headers });
}

async function latestTable(): Promise<{ edition: SalesTaxEdition; rows: SalesTaxRow[] }> {
  const failures: string[] = [];
  for (const edition of candidateEditions(new Date())) {
    const res = await fetch(edition.url, {
      headers: { "User-Agent": "tippos-sales-tax-refresh/1.0 (+https://discover.tippos.app)" },
      signal: AbortSignal.timeout(20_000),
    });
    if (!res.ok) {
      await res.body?.cancel();
      failures.push(`${edition.slug}: HTTP ${res.status}`);
      continue;
    }
    try {
      const rows = parseSalesTaxTable(await res.text());
      const problems = checkSalesTaxRows(rows);
      if (problems.length) throw new Error(problems.join("; "));
      return { edition, rows };
    } catch (e) {
      failures.push(`${edition.slug}: ${(e as Error).message}`);
    }
  }
  throw new Error(`no usable Tax Foundation table (${failures.join(" | ")})`);
}

async function refresh(): Promise<Response> {
  const { edition, rows } = await latestTable();
  const db = adminClient();
  const fetchedAt = new Date().toISOString();
  const { error } = await db.from("sales_tax_rates").upsert(
    rows.map((r) => ({
      ...r,
      edition: edition.slug,
      as_of: edition.as_of,
      source_url: edition.url,
      fetched_at: fetchedAt,
    })),
    { onConflict: "state" },
  );
  if (error) throw new Error(`store failed: ${error.message}`);
  return jsonResponse({ ok: true, edition: edition.slug, as_of: edition.as_of, states: rows.length });
}

async function read(): Promise<Response> {
  const { data, error } = await adminClient()
    .from("sales_tax_rates")
    .select("state, state_rate, local_rate, combined_rate, edition, as_of, source_url, fetched_at")
    .order("state");
  if (error) return jsonResponse({ error: "read_failed" }, 500);
  return jsonResponse({ rates: data ?? [] });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method === "GET") {
    // Rates change at most twice a year; let browsers and the CDN keep them for a day.
    return withCors(await read(), { "Cache-Control": "public, max-age=86400" });
  }
  if (req.method !== "POST") return withCors(jsonResponse({ error: "method_not_allowed" }, 405));
  if (!(await hasBackendAccess(req))) return withCors(jsonResponse({ error: "unauthorized" }, 401));
  try {
    return withCors(await refresh());
  } catch (e) {
    console.error("sales-tax refresh failed:", (e as Error).message);
    return withCors(jsonResponse({ ok: false, error: (e as Error).message }, 502));
  }
});
