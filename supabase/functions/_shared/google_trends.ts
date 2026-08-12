export const GOOGLE_TRENDS_DATASET_KINDS = [
  "interest_over_time",
  "interest_by_subregion",
  "related_queries",
  "related_topics",
] as const;

export type GoogleTrendsDatasetKind =
  (typeof GOOGLE_TRENDS_DATASET_KINDS)[number];

type InterestPoint = {
  observed_on: string;
  raw_value: string;
  relative_interest: number | null;
  is_suppressed: boolean;
};

type GeoMetric = {
  region_name: string;
  region_code: string | null;
  raw_value: string;
  relative_interest: number | null;
  is_suppressed: boolean;
};

type RelatedTerm = {
  ranking_kind: "top" | "rising";
  rank: number;
  term: string;
  raw_value: string;
  score: number | null;
  is_breakout: boolean;
};

export type ParsedGoogleTrendsExport = {
  interest_over_time?: InterestPoint[];
  geo_metrics?: GeoMetric[];
  related_terms?: RelatedTerm[];
};

export type ParsedGoogleTrendsSeries = ParsedGoogleTrendsExport & {
  query_text: string;
  series_key: string;
  metric_interpretation:
    | "relative_interest_index_0_100_not_search_volume"
    | "comparison_share_percentage_0_100_within_exact_export_not_search_volume";
};

function csvRows(input: string): string[][] {
  if (!input.trim() || input.length > 500_000) {
    throw new Error("invalid_google_trends_csv");
  }
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  const csv = input.replace(/^\uFEFF/, "");

  for (let index = 0; index < csv.length; index += 1) {
    const character = csv[index];
    if (character === '"') {
      if (quoted && csv[index + 1] === '"') {
        cell += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (character === "," && !quoted) {
      row.push(cell.trim());
      cell = "";
    } else if (character === "\n" && !quoted) {
      row.push(cell.trim());
      if (row.some((value) => value.length > 0)) rows.push(row);
      row = [];
      cell = "";
    } else if (character !== "\r" || quoted) {
      cell += character;
    }
  }
  if (quoted) throw new Error("invalid_google_trends_csv");
  row.push(cell.trim());
  if (row.some((value) => value.length > 0)) rows.push(row);
  return rows;
}

function parseObservedOn(value: string): string | null {
  const iso = value.match(/\b(\d{4}-\d{2}-\d{2})\b/);
  if (iso) return iso[1];
  const month = value.match(/^\s*(\d{4})-(\d{2})\s*$/);
  if (month) return `${month[1]}-${month[2]}-01`;
  const year = value.match(/^\s*(\d{4})\s*$/);
  if (year) return `${year[1]}-01-01`;
  const timestamp = Date.parse(value);
  return Number.isNaN(timestamp)
    ? null
    : new Date(timestamp).toISOString().slice(0, 10);
}

function parseRelativeInterest(value: string): {
  relative_interest: number | null;
  is_suppressed: boolean;
} {
  const normalized = value.trim();
  if (/^<\s*1$/i.test(normalized)) {
    return { relative_interest: null, is_suppressed: true };
  }
  if (!/^\d+(?:\.\d+)?$/.test(normalized)) {
    throw new Error("invalid_google_trends_relative_interest");
  }
  const relativeInterest = Number(normalized);
  if (relativeInterest < 0 || relativeInterest > 100) {
    throw new Error("invalid_google_trends_relative_interest");
  }
  return { relative_interest: relativeInterest, is_suppressed: false };
}

function findHeader(rows: string[][], expectedFirstColumn: RegExp): number {
  const headerIndex = rows.findIndex((row) => expectedFirstColumn.test(row[0] ?? ""));
  if (headerIndex < 0) throw new Error("unsupported_google_trends_csv");
  return headerIndex;
}

function singleValueColumn(header: string[]): number {
  const columns = header
    .map((value, index) => ({ value, index }))
    .filter(({ value, index }) => index > 0 && value.trim().length > 0);
  if (columns.length !== 1) {
    throw new Error("google_trends_single_series_required");
  }
  return columns[0].index;
}

function parseInterestOverTime(rows: string[][]): ParsedGoogleTrendsExport {
  const headerIndex = findHeader(rows, /^(day|week|month)$/i);
  const valueColumn = singleValueColumn(rows[headerIndex]);
  const interest_over_time: InterestPoint[] = [];
  for (const row of rows.slice(headerIndex + 1)) {
    const observedOn = parseObservedOn(row[0] ?? "");
    if (!observedOn) continue;
    const rawValue = (row[valueColumn] ?? "").trim();
    if (!rawValue) continue;
    interest_over_time.push({
      observed_on: observedOn,
      raw_value: rawValue,
      ...parseRelativeInterest(rawValue),
    });
  }
  if (!interest_over_time.length) throw new Error("google_trends_csv_has_no_rows");
  return { interest_over_time };
}

function parseGeoMetrics(rows: string[][]): ParsedGoogleTrendsExport {
  const headerIndex = findHeader(rows, /^(subregion|region|metro|city)$/i);
  const valueColumn = singleValueColumn(rows[headerIndex]);
  const geo_metrics: GeoMetric[] = [];
  for (const row of rows.slice(headerIndex + 1)) {
    const regionName = (row[0] ?? "").trim();
    const rawValue = (row[valueColumn] ?? "").trim();
    if (!regionName || !rawValue) continue;
    geo_metrics.push({
      region_name: regionName,
      region_code: null,
      raw_value: rawValue,
      ...parseRelativeInterest(rawValue),
    });
  }
  if (!geo_metrics.length) throw new Error("google_trends_csv_has_no_rows");
  return { geo_metrics };
}

function parseRelatedTerms(
  rows: string[][],
  relation: "queries" | "topics",
): ParsedGoogleTrendsExport {
  const related_terms: RelatedTerm[] = [];
  const ranks: Record<"top" | "rising", number> = { top: 0, rising: 0 };
  let rankingKind: "top" | "rising" = "top";
  let inTable = false;

  for (const row of rows) {
    const first = (row[0] ?? "").trim();
    const normalizedFirst = first.toLowerCase();
    if (normalizedFirst === "top" || normalizedFirst === "rising") {
      rankingKind = normalizedFirst;
      inTable = false;
      continue;
    }
    if (normalizedFirst === `related ${relation}`) {
      inTable = true;
      continue;
    }
    if (!inTable || !first) continue;
    const rawValue = (row[1] ?? "").trim();
    if (!rawValue || normalizedFirst === "value") continue;
    const isBreakout = /^breakout$/i.test(rawValue);
    if (!isBreakout && !/^\d+(?:\.\d+)?$/.test(rawValue)) {
      throw new Error("invalid_google_trends_related_term");
    }
    ranks[rankingKind] += 1;
    related_terms.push({
      ranking_kind: rankingKind,
      rank: ranks[rankingKind],
      term: first,
      raw_value: rawValue,
      score: isBreakout ? null : Number(rawValue),
      is_breakout: isBreakout,
    });
  }
  if (!related_terms.length) throw new Error("google_trends_csv_has_no_rows");
  return { related_terms };
}

export function parseGoogleTrendsCsv(
  datasetKind: GoogleTrendsDatasetKind,
  csv: string,
): ParsedGoogleTrendsExport {
  const rows = csvRows(csv);
  switch (datasetKind) {
    case "interest_over_time":
      return parseInterestOverTime(rows);
    case "interest_by_subregion":
      return parseGeoMetrics(rows);
    case "related_queries":
      return parseRelatedTerms(rows, "queries");
    case "related_topics":
      return parseRelatedTerms(rows, "topics");
  }
}

function comparisonSeriesColumns(header: string[]): Array<{
  index: number;
  query_text: string;
  series_key: string;
}> {
  const columns = header
    .map((value, index) => ({ value: value.trim(), index }))
    .filter(({ value, index }) => index > 0 && value.length > 0);
  if (!columns.length) throw new Error("google_trends_csv_has_no_series");
  return columns.map(({ value, index }) => {
    const queryText = value.replace(/\s*:\s*\([^)]*\)\s*$/, "").trim();
    if (!queryText || queryText.length > 500) {
      throw new Error("invalid_google_trends_series_name");
    }
    return { index, query_text: queryText, series_key: `series-${index}` };
  });
}

function parseComparisonValue(value: string, allowPercentage: boolean): {
  relative_interest: number | null;
  is_suppressed: boolean;
} {
  const normalized = value.trim();
  if (/^<\s*1$/i.test(normalized)) {
    return { relative_interest: null, is_suppressed: true };
  }
  const numericValue = allowPercentage && /^\d+(?:\.\d+)?%$/.test(normalized)
    ? normalized.slice(0, -1)
    : normalized;
  if (!/^\d+(?:\.\d+)?$/.test(numericValue)) {
    throw new Error("invalid_google_trends_relative_interest");
  }
  const relativeInterest = Number(numericValue);
  if (relativeInterest < 0 || relativeInterest > 100) {
    throw new Error("invalid_google_trends_relative_interest");
  }
  return { relative_interest: relativeInterest, is_suppressed: false };
}

function parseComparisonInterestOverTime(rows: string[][]): ParsedGoogleTrendsSeries[] {
  const headerIndex = findHeader(rows, /^(day|week|month)$/i);
  const parsed = comparisonSeriesColumns(rows[headerIndex]).map((column) => ({
    ...column,
    metric_interpretation: "relative_interest_index_0_100_not_search_volume" as const,
    interest_over_time: [] as InterestPoint[],
  }));
  for (const row of rows.slice(headerIndex + 1)) {
    const observedOn = parseObservedOn(row[0] ?? "");
    if (!observedOn) continue;
    parsed.forEach((series) => {
      const rawValue = (row[series.index] ?? "").trim();
      if (!rawValue) return;
      series.interest_over_time.push({
        observed_on: observedOn,
        raw_value: rawValue,
        ...parseComparisonValue(rawValue, false),
      });
    });
  }
  if (parsed.some((series) => !series.interest_over_time.length)) {
    throw new Error("google_trends_csv_has_no_rows");
  }
  return parsed;
}

function parseComparisonGeoMetrics(rows: string[][]): ParsedGoogleTrendsSeries[] {
  const headerIndex = findHeader(rows, /^(subregion|region|metro|city)$/i);
  const columns = comparisonSeriesColumns(rows[headerIndex]);
  const isComparison = columns.length > 1;
  const parsed = columns.map((column) => ({
    ...column,
    metric_interpretation: isComparison
      ? "comparison_share_percentage_0_100_within_exact_export_not_search_volume" as const
      : "relative_interest_index_0_100_not_search_volume" as const,
    geo_metrics: [] as GeoMetric[],
  }));
  for (const row of rows.slice(headerIndex + 1)) {
    const regionName = (row[0] ?? "").trim();
    if (!regionName) continue;
    parsed.forEach((series) => {
      const rawValue = (row[series.index] ?? "").trim();
      if (!rawValue) return;
      series.geo_metrics.push({
        region_name: regionName,
        region_code: null,
        raw_value: rawValue,
        ...parseComparisonValue(rawValue, isComparison),
      });
    });
  }
  if (parsed.some((series) => !series.geo_metrics.length)) {
    throw new Error("google_trends_csv_has_no_rows");
  }
  return parsed;
}

export function parseGoogleTrendsComparisonCsv(
  datasetKind: "interest_over_time" | "interest_by_subregion",
  csv: string,
): ParsedGoogleTrendsSeries[] {
  const rows = csvRows(csv);
  return datasetKind === "interest_over_time"
    ? parseComparisonInterestOverTime(rows)
    : parseComparisonGeoMetrics(rows);
}

export function isGoogleTrendsDatasetKind(
  value: unknown,
): value is GoogleTrendsDatasetKind {
  return typeof value === "string" &&
    GOOGLE_TRENDS_DATASET_KINDS.includes(value as GoogleTrendsDatasetKind);
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}
