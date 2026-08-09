import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
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
