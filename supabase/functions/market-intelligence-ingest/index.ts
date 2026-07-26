import {
  adminClient,
  hasIngestAccess,
  jsonResponse,
} from "../_shared/market_intelligence_runtime.ts";
import {
  parseCsv,
  validateAiVisibilityPayload,
  validateSearchObservations,
} from "../_shared/market_intelligence.ts";

const MAX_BODY_BYTES = 1_000_000;

function publicError(error: unknown): string {
  const message = error instanceof Error ? error.message : "invalid_request";
  return /^[a-z0-9_]+$/.test(message) ? message : "invalid_request";
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return jsonResponse({ error: "method_not_allowed" }, 405);
  }
  if (!(await hasIngestAccess(req))) {
    return jsonResponse({ error: "unauthorized" }, 401);
  }
  const contentLength = Number(req.headers.get("content-length") ?? 0);
  if (contentLength > MAX_BODY_BYTES) {
    return jsonResponse({ error: "payload_too_large" }, 413);
  }

  try {
    const contentType = (req.headers.get("content-type") ?? "").split(";", 1)[0]
      .trim().toLowerCase();
    const raw = await req.text();
    if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
      return jsonResponse({ error: "payload_too_large" }, 413);
    }
    const idempotencyKey = req.headers.get("idempotency-key")?.trim() ?? "";
    if (idempotencyKey.length < 8 || idempotencyKey.length > 200) {
      return jsonResponse({ error: "invalid_idempotency_key" }, 400);
    }

    if (contentType === "text/csv") {
      const observations = validateSearchObservations(parseCsv(raw));
      const sourceKey = req.headers.get("x-source-key")?.trim() || "manual_csv";
      const { data, error } = await adminClient().rpc(
        "mi_import_search_metrics",
        {
          p_source_key: sourceKey,
          p_external_job_key: idempotencyKey,
          p_observations: observations,
          p_dry_run: req.headers.get("x-dry-run") === "true",
        },
      );
      if (error) throw new Error("ingestion_failed");
      return jsonResponse(data, 200);
    }

    if (contentType !== "application/json") {
      return jsonResponse({ error: "unsupported_content_type" }, 415);
    }
    const body = JSON.parse(raw) as Record<string, unknown>;
    if (body.kind === "search_metrics") {
      const observations = validateSearchObservations(body.observations);
      const sourceKey = typeof body.source_key === "string"
        ? body.source_key
        : "manual_csv";
      const { data, error } = await adminClient().rpc(
        "mi_import_search_metrics",
        {
          p_source_key: sourceKey,
          p_external_job_key: idempotencyKey,
          p_observations: observations,
          p_dry_run: body.dry_run === true,
        },
      );
      if (error) throw new Error("ingestion_failed");
      return jsonResponse(data, 200);
    }
    if (body.kind === "ai_visibility") {
      const payload = validateAiVisibilityPayload(body.payload);
      const { data, error } = await adminClient().rpc(
        "mi_record_ai_visibility",
        {
          p_source_key: payload.source_key,
          p_prompt_key: payload.prompt_key,
          p_idempotency_key: idempotencyKey,
          p_provider_model: payload.provider_model,
          p_status: payload.status,
          p_response_summary: payload.response_summary,
          p_response_text: payload.response_text ?? null,
          p_retention_mode: payload.retention_mode,
          p_mentions: payload.mentions,
          p_citations: payload.citations,
          p_metrics: payload.metrics ?? {},
        },
      );
      if (error) throw new Error("ingestion_failed");
      return jsonResponse(data, 200);
    }
    return jsonResponse({ error: "unsupported_ingestion_kind" }, 400);
  } catch (error) {
    console.error(
      "[market-intelligence-ingest] request_failed",
      publicError(error),
    );
    return jsonResponse({ error: publicError(error) }, 400);
  }
});
