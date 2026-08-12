import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  parseGoogleTrendsComparisonCsv,
  parseGoogleTrendsCsv,
  sha256Hex,
} from "./google_trends.ts";

Deno.test("parses a single-series Google Trends interest-over-time export", () => {
  const parsed = parseGoogleTrendsCsv(
    "interest_over_time",
    "Category: All categories\n\nWeek,how much should i tip\n2026-07-05,57\n2026-07-12,<1\n",
  );
  assertEquals(parsed.interest_over_time, [
    {
      observed_on: "2026-07-05",
      raw_value: "57",
      relative_interest: 57,
      is_suppressed: false,
    },
    {
      observed_on: "2026-07-12",
      raw_value: "<1",
      relative_interest: null,
      is_suppressed: true,
    },
  ]);
});

Deno.test("rejects a Google Trends comparison export because values are not comparable", () => {
  assertThrows(() =>
    parseGoogleTrendsCsv(
      "interest_over_time",
      "Week,tip,tipping\n2026-07-05,57,43\n",
    )
  );
});

Deno.test("parses each term in a Google Trends interest-over-time comparison", () => {
  const parsed = parseGoogleTrendsComparisonCsv(
    "interest_over_time",
    "Month,tip with card: (United States),tip by card: (United States)\n2026-04,100,27\n2026-05,67,18\n2026-06,58,14\n",
  );
  assertEquals(parsed.map((series) => ({
    query_text: series.query_text,
    series_key: series.series_key,
    metric_interpretation: series.metric_interpretation,
    values: series.interest_over_time,
  })), [
    {
      query_text: "tip with card",
      series_key: "series-1",
      metric_interpretation: "relative_interest_index_0_100_not_search_volume",
      values: [
        { observed_on: "2026-04-01", raw_value: "100", relative_interest: 100, is_suppressed: false },
        { observed_on: "2026-05-01", raw_value: "67", relative_interest: 67, is_suppressed: false },
        { observed_on: "2026-06-01", raw_value: "58", relative_interest: 58, is_suppressed: false },
      ],
    },
    {
      query_text: "tip by card",
      series_key: "series-2",
      metric_interpretation: "relative_interest_index_0_100_not_search_volume",
      values: [
        { observed_on: "2026-04-01", raw_value: "27", relative_interest: 27, is_suppressed: false },
        { observed_on: "2026-05-01", raw_value: "18", relative_interest: 18, is_suppressed: false },
        { observed_on: "2026-06-01", raw_value: "14", relative_interest: 14, is_suppressed: false },
      ],
    },
  ]);
});

Deno.test("labels multi-term Google Trends geography percentages as comparison shares", () => {
  const parsed = parseGoogleTrendsComparisonCsv(
    "interest_by_subregion",
    "Subregion,tip with card: (United States),tip by card: (United States)\nWyoming,36%,13%\nNew York,51%,27%\n",
  );
  assertEquals(parsed[0].metric_interpretation,
    "comparison_share_percentage_0_100_within_exact_export_not_search_volume");
  assertEquals(parsed[0].geo_metrics, [
    { region_name: "Wyoming", region_code: null, raw_value: "36%", relative_interest: 36, is_suppressed: false },
    { region_name: "New York", region_code: null, raw_value: "51%", relative_interest: 51, is_suppressed: false },
  ]);
  assertEquals(parsed[1].geo_metrics?.[0], {
    region_name: "Wyoming", region_code: null, raw_value: "13%", relative_interest: 13, is_suppressed: false,
  });
});

Deno.test("parses Google Trends subregion and related-query exports", () => {
  assertEquals(
    parseGoogleTrendsCsv(
      "interest_by_subregion",
      "Subregion,how much should i tip\nNew York,100\nAlaska,<1\n",
    ).geo_metrics,
    [
      {
        region_name: "New York",
        region_code: null,
        raw_value: "100",
        relative_interest: 100,
        is_suppressed: false,
      },
      {
        region_name: "Alaska",
        region_code: null,
        raw_value: "<1",
        relative_interest: null,
        is_suppressed: true,
      },
    ],
  );
  assertEquals(
    parseGoogleTrendsCsv(
      "related_queries",
      "Top\nRelated queries,Value\ntip etiquette,100\n\nRising\nRelated queries,Value\ntip calculator,Breakout\n",
    ).related_terms,
    [
      {
        ranking_kind: "top",
        rank: 1,
        term: "tip etiquette",
        raw_value: "100",
        score: 100,
        is_breakout: false,
      },
      {
        ranking_kind: "rising",
        rank: 1,
        term: "tip calculator",
        raw_value: "Breakout",
        score: null,
        is_breakout: true,
      },
    ],
  );
});

Deno.test("hashes raw Google Trends exports without retaining their file contents", async () => {
  assertEquals(
    await sha256Hex("Week,tip\n2026-07-05,57\n"),
    "6e0ca798eaa4498d63d86850a7d43277936f6a92b1463e5207e04fa40b16a224",
  );
});
