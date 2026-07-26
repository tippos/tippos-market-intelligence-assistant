import {
  adminClient,
  hasBackendAccess,
  jsonResponse,
} from "../_shared/market_intelligence_runtime.ts";
import {
  extractCitations,
  extractOutputText,
  type OpenAIResponse,
  tipposMentions,
} from "../_shared/openai_visibility.ts";

const MAX_PROMPTS_PER_RUN = 20;
const DEFAULT_MODEL = "gpt-5.6-terra";

function safeKey(value: unknown): value is string {
  return typeof value === "string" && /^[a-z0-9][a-z0-9_-]{1,199}$/.test(value);
}

async function createResponse(
  apiKey: string,
  model: string,
  prompt: string,
  useWebSearch: boolean,
): Promise<OpenAIResponse> {
  const body: Record<string, unknown> = {
    model,
    input: prompt,
    reasoning: { effort: "low" },
    max_output_tokens: 1200,
  };
  if (useWebSearch) body.tools = [{ type: "web_search" }];
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(45_000),
  });
  const data = await response.json().catch(() => ({})) as OpenAIResponse;
  if (!response.ok) throw new Error(`openai_${response.status}`);
  return data;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }
  if (!(await hasBackendAccess(req))) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  const openaiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
  if (!openaiKey) {
    return jsonResponse({ error: "openai_credentials_missing" }, 503);
  }

  try {
    const body = await req.json() as Record<string, unknown>;
    const requestKey = req.headers.get("idempotency-key")?.trim() ?? "";
    if (!safeKey(requestKey)) {
      return jsonResponse({ error: "invalid_idempotency_key" }, 400);
    }
    const requested = Array.isArray(body.prompt_keys) ? body.prompt_keys : null;
    if (
      requested &&
      (requested.length === 0 || requested.length > MAX_PROMPTS_PER_RUN ||
        requested.some((key) => !safeKey(key)))
    ) {
      return jsonResponse({ error: "invalid_prompt_keys" }, 400);
    }
    const model = Deno.env.get("OPENAI_VISIBILITY_MODEL") || DEFAULT_MODEL;
    const useWebSearch =
      Deno.env.get("OPENAI_VISIBILITY_WEB_SEARCH") === "true";
    const { data: prompts, error: promptError } = await adminClient().rpc(
      "mi_get_active_prompts",
      {
        p_prompt_keys: requested,
      },
    );
    if (promptError) throw new Error("prompt_read_failed");
    const selected = (prompts ?? []).slice(0, MAX_PROMPTS_PER_RUN) as Array<
      { prompt_key: string; prompt_text: string; language_code: string }
    >;
    if (selected.length === 0) {
      return jsonResponse({ error: "no_active_prompts" }, 400);
    }

    const results: Array<Record<string, unknown>> = [];
    for (const prompt of selected) {
      const started = performance.now();
      const runKey = `${requestKey}-${prompt.prompt_key}`.slice(0, 200);
      try {
        const response = await createResponse(
          openaiKey,
          model,
          prompt.prompt_text,
          useWebSearch,
        );
        const text = extractOutputText(response);
        if (!text) throw new Error("openai_empty_response");
        const usage = response.usage && typeof response.usage === "object"
          ? response.usage as Record<string, unknown>
          : {};
        const { data, error } = await adminClient().rpc(
          "mi_record_ai_visibility",
          {
            p_source_key: "openai_visibility",
            p_prompt_key: prompt.prompt_key,
            p_idempotency_key: runKey,
            p_provider_model: model,
            p_status: "succeeded",
            p_response_summary: {
              answer_excerpt: text.slice(0, 1000),
              response_id: response.id ?? null,
              web_search_enabled: useWebSearch,
            },
            p_response_text: null,
            p_retention_mode: "summary",
            p_mentions: tipposMentions(text),
            p_citations: extractCitations(response),
            p_metrics: {
              latency_ms: Math.round(performance.now() - started),
              input_tokens: usage.input_tokens,
              output_tokens: usage.output_tokens,
              model_version: response.model,
            },
          },
        );
        if (error) throw new Error("visibility_write_failed");
        results.push({ prompt_key: prompt.prompt_key, ok: true, run: data });
      } catch (error) {
        const code =
          error instanceof Error && /^[a-z0-9_]+$/.test(error.message)
            ? error.message
            : "provider_run_failed";
        await adminClient().rpc("mi_record_ai_visibility", {
          p_source_key: "openai_visibility",
          p_prompt_key: prompt.prompt_key,
          p_idempotency_key: runKey,
          p_provider_model: model,
          p_status: "failed",
          p_response_summary: {},
          p_response_text: null,
          p_retention_mode: "metadata_only",
          p_mentions: [],
          p_citations: [],
          p_metrics: {
            latency_ms: Math.round(performance.now() - started),
            error_code: code,
          },
        });
        results.push({ prompt_key: prompt.prompt_key, ok: false, error: code });
      }
    }
    return jsonResponse({
      ok: results.every((result) => result.ok),
      model,
      web_search_enabled: useWebSearch,
      results,
    });
  } catch (error) {
    console.error(
      "[market-intelligence-openai] run_failed",
      error instanceof Error ? error.message : "unknown",
    );
    return jsonResponse({ error: "run_failed" }, 400);
  }
});
