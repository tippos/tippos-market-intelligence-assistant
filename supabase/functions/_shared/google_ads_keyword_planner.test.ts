import {
  assertEquals,
  assertRejects,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  createObservationBatchKey,
  createObservationBatches,
  createGoogleAdsAssertion,
  mapHistoricalKeywordMetrics,
  mergeKeywordCandidates,
  validateKeywordCandidateLimit,
  validateReviewedKeywords,
  validateKeywordSeeds,
} from "./google_ads_keyword_planner.ts";

Deno.test("validates and case-insensitively deduplicates keyword seeds", () => {
  assertEquals(
    validateKeywordSeeds([
      " Tip Calculator ",
      "tip calculator",
      "tip calculator per person",
    ]),
    ["Tip Calculator", "tip calculator per person"],
  );
  assertThrows(() => validateKeywordSeeds([]));
  assertThrows(() =>
    validateKeywordSeeds(Array.from({ length: 21 }, (_, i) => `keyword ${i}`))
  );
});

Deno.test("accepts up to 1,000 reviewed historical-metric keywords", () => {
  const keywords = Array.from({ length: 1_000 }, (_, i) => `keyword ${i}`);
  assertEquals(validateReviewedKeywords(keywords).length, 1_000);
  assertThrows(() => validateReviewedKeywords([...keywords, "keyword 1000"]));
  assertEquals(validateKeywordCandidateLimit(1_000), 1_000);
  assertThrows(() => validateKeywordCandidateLimit(1_001));
});

Deno.test("keeps seeds first and treats keyword ideas as candidates only", () => {
  assertEquals(
    mergeKeywordCandidates(
      ["tip calculator", "split tip calculator"],
      [
        { text: " Tip Calculator " },
        { text: "tip calculator for groups" },
        { text: null },
      ],
      3,
    ),
    ["tip calculator", "split tip calculator", "tip calculator for groups"],
  );
});

Deno.test("sorts and content-binds observation batches deterministically", async () => {
  const observations = Array.from({ length: 1_001 }, (_, index) => ({
    query: `keyword ${String(1_000 - index).padStart(4, "0")}`,
    language_code: "en",
    country_code: "US",
    observed_on: "2026-06-01",
    granularity: "month" as const,
    search_volume: index,
  }));
  const forward = createObservationBatches(observations);
  const reversed = createObservationBatches([...observations].reverse());
  assertEquals(forward.map((batch) => batch.length), [1_000, 1]);
  assertEquals(forward, reversed);
  assertEquals(
    await createObservationBatchKey("google-ads-202607", forward[0], 1),
    await createObservationBatchKey("google-ads-202607", reversed[0], 1),
  );
});

Deno.test("maps monthly historical metrics with explicit provider limitations", () => {
  const rows = mapHistoricalKeywordMetrics(
    [{
      text: "tip calculator per person",
      closeVariants: ["tip calculator for each person"],
      keywordMetrics: {
        avgMonthlySearches: "1000",
        competition: "MEDIUM",
        competitionIndex: "34",
        averageCpcMicros: "1250000",
        lowTopOfPageBidMicros: "500000",
        highTopOfPageBidMicros: "2000000",
        monthlySearchVolumes: [
          { year: "2026", month: "JUNE", monthlySearches: "880" },
          { year: "2026", month: "JULY", monthlySearches: "1120" },
        ],
      },
    }],
    "en",
    "US",
  );

  assertEquals(rows.length, 2);
  assertEquals(rows[0].observed_on, "2026-06-01");
  assertEquals(rows[0].search_volume, 880);
  assertEquals(rows[0].competition, 0.34);
  assertEquals(rows[0].cpc, 1.25);
  assertEquals(rows[0].granularity, "month");
  assertEquals(rows[0].confidence, 0.8);
  assertEquals(rows[0].source_metadata, {
    provider_metric: "approximate_monthly_searches",
    aggregation: "keyword_and_close_variants",
    average_monthly_searches: 1000,
    close_variants: ["tip calculator for each person"],
    competition_level: "MEDIUM",
    competition_index: 34,
    average_cpc_micros: 1250000,
    low_top_of_page_bid_micros: 500000,
    high_top_of_page_bid_micros: 2000000,
  });
});

Deno.test("drops malformed provider rows instead of fabricating zero volume", () => {
  const rows = mapHistoricalKeywordMetrics(
    [{
      text: "tip calculator",
      keywordMetrics: {
        avgMonthlySearches: "1000",
        monthlySearchVolumes: [
          { year: "2026", month: "UNSPECIFIED", monthlySearches: "1000" },
          { year: "2026", month: "JULY", monthlySearches: "not-a-number" },
        ],
      },
    }],
    "en",
    "US",
  );
  assertEquals(rows, []);
});

Deno.test("rejects an invalid service-account key", async () => {
  await assertRejects(() =>
    createGoogleAdsAssertion("service@example.test", "not-a-key")
  );
});
