// Sales-tax rates for the brand site's tax-and-tip calculator, read from Tax
// Foundation's state-and-local sales tax table.
//
// The table is plain HTML, so this is a parser, not a model: the numbers are
// copied cell by cell and checked against each other before anything is
// stored. If any check fails the refresh stores nothing and the site keeps the
// last good rates.

export type SalesTaxRow = {
  state: string;
  state_rate: number;
  local_rate: number;
  combined_rate: number;
};

export type SalesTaxEdition = {
  /** e.g. "2026-sales-tax-rates-midyear" */
  slug: string;
  url: string;
  /** Effective date of the table: 1 January or 1 July of its year. */
  as_of: string;
};

const BASE = "https://taxfoundation.org/data/all/state/";

/**
 * Candidate editions, newest first. Tax Foundation publishes a January table
 * ("<year>-sales-tax-rates") and a midyear one ("<year>-sales-tax-rates-midyear").
 */
export function candidateEditions(today: Date): SalesTaxEdition[] {
  const year = today.getUTCFullYear();
  const out: SalesTaxEdition[] = [];
  for (const y of [year + 1, year, year - 1]) {
    out.push({
      slug: `${y}-sales-tax-rates-midyear`,
      url: `${BASE}${y}-sales-tax-rates-midyear/`,
      as_of: `${y}-07-01`,
    });
    out.push({
      slug: `${y}-sales-tax-rates`,
      url: `${BASE}${y}-sales-tax-rates/`,
      as_of: `${y}-01-01`,
    });
  }
  return out.filter((e) => e.as_of <= today.toISOString().slice(0, 10));
}

function decode(text: string): string {
  return text
    .replace(/<[^>]*>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&#8217;|&rsquo;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .trim();
}

function percent(cell: string): number {
  const n = Number.parseFloat(cell.replace("%", ""));
  if (!Number.isFinite(n)) throw new Error(`not a percentage: ${cell}`);
  return n;
}

/** Reads the first table on the page into rows. Throws if its header is not the expected one. */
export function parseSalesTaxTable(html: string): SalesTaxRow[] {
  const start = html.indexOf("<table");
  const end = html.indexOf("</table>", start);
  if (start < 0 || end < 0) throw new Error("no table on the page");
  const rows = [...html.slice(start, end).matchAll(/<tr[\s\S]*?<\/tr>/g)].map((m) =>
    [...m[0].matchAll(/<t[hd][\s\S]*?<\/t[hd]>/g)].map((c) => decode(c[0]))
  );
  const header = rows.shift() ?? [];
  const expected = ["State", "State Tax Rate", "State Tax Rank", "Average Local Tax Rate"];
  if (expected.some((h, i) => header[i] !== h) || header[5] !== "Combined Tax Rate") {
    throw new Error(`unexpected table header: ${header.join(" | ")}`);
  }
  return rows
    .filter((r) => r.length >= 6 && r[0])
    .map((r) => ({
      state: r[0] === "DC" ? "District of Columbia" : r[0],
      state_rate: percent(r[1]),
      local_rate: percent(r[3]),
      combined_rate: percent(r[5]),
    }));
}

/** Every reason a parsed table must not be stored. Empty means it is safe. */
export function checkSalesTaxRows(rows: SalesTaxRow[]): string[] {
  const problems: string[] = [];
  if (rows.length < 51) problems.push(`only ${rows.length} rows, expected 51`);
  const seen = new Set<string>();
  for (const r of rows) {
    if (seen.has(r.state)) problems.push(`${r.state} appears twice`);
    seen.add(r.state);
    if (r.combined_rate < 0 || r.combined_rate > 15) {
      problems.push(`${r.state} combined rate ${r.combined_rate}% is out of range`);
    }
    if (r.state_rate < 0 || r.state_rate > 12) {
      problems.push(`${r.state} state rate ${r.state_rate}% is out of range`);
    }
    // Tax Foundation rounds each column to two decimals, so the parts can be a cent off.
    if (Math.abs(r.state_rate + r.local_rate - r.combined_rate) > 0.015) {
      problems.push(`${r.state}: ${r.state_rate} + ${r.local_rate} != ${r.combined_rate}`);
    }
  }
  for (const must of ["California", "Texas", "New York", "Tennessee"]) {
    if (!seen.has(must)) problems.push(`${must} is missing`);
  }
  return problems;
}
