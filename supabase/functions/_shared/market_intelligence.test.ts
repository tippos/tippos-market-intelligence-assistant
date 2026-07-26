import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  validateAiVisibilityPayload,
  validateSearchObservations,
} from "./market_intelligence.ts";

Deno.test("search observation parsing normalizes provider values", () => {
  const [row] = validateSearchObservations([{
    query: "cashless tipping",
    language_code: "en",
    country_code: "us",
    observed_on: "2026-07-23",
  }]);
  assertEquals(row.country_code, "US");
});

Deno.test("search observations reject invalid language tags and score ranges", () => {
  assertThrows(() =>
    validateSearchObservations([{
      query: "x",
      language_code: "ENGLISH",
      observed_on: "2026-07-23",
    }])
  );
  assertThrows(() =>
    validateSearchObservations([{
      query: "x",
      language_code: "en",
      observed_on: "2026-07-23",
      competition: 2,
    }])
  );
});

Deno.test("search observations preserve bounded provider metadata", () => {
  const [row] = validateSearchObservations([{
    query: "tip calculator",
    language_code: "en",
    country_code: "US",
    observed_on: "2026-07-01",
    search_volume: 1000,
    source_metadata: {
      provider_metric: "approximate_monthly_searches",
      close_variants: ["tip calculator app"],
    },
  }]);
  assertEquals(row.source_metadata, {
    provider_metric: "approximate_monthly_searches",
    close_variants: ["tip calculator app"],
  });
  assertThrows(() =>
    validateSearchObservations([{
      query: "tip calculator",
      language_code: "en",
      observed_on: "2026-07-01",
      source_metadata: [],
    }])
  );
});

Deno.test("AI visibility blocks full text unless explicitly retained", () => {
  assertThrows(() =>
    validateAiVisibilityPayload({
      source_key: "openai_visibility",
      prompt_key: "production-prompt-en",
      idempotency_key: "provider-run-0001",
      provider_model: "gpt-5-mini",
      status: "succeeded",
      response_summary: {},
      response_text: "not allowed",
      retention_mode: "summary",
      mentions: [],
      citations: [],
    })
  );
});
