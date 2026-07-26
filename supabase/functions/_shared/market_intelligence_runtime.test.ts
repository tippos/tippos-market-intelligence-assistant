import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  hasBackendAccess,
  hasIngestAccess,
} from "./market_intelligence_runtime.ts";

Deno.test("accepts a named Supabase secret key", async () => {
  const key = "fixture_backend_key_123456789012345";
  const req = new Request("https://example.test", { headers: { apikey: key } });
  assertEquals(
    await hasBackendAccess(req, {
      secretKeysJson: JSON.stringify({ default: key }),
    }),
    true,
  );
});

Deno.test("accepts an optional custom key only at the ingest boundary", async () => {
  const req = new Request("https://example.test", {
    headers: { authorization: "Bearer custom_ingest_key_123456789012345" },
  });
  assertEquals(
    await hasIngestAccess(req, {
      customIngestKey: "custom_ingest_key_123456789012345",
    }),
    true,
  );
  assertEquals(
    await hasBackendAccess(req, {
      customIngestKey: "custom_ingest_key_123456789012345",
    }),
    false,
  );
});

Deno.test("rejects publishable and unknown keys", async () => {
  const req = new Request("https://example.test", {
    headers: { apikey: "sb_publishable_not_authorized_123456" },
  });
  assertEquals(
    await hasBackendAccess(req, {
      secretKeysJson: JSON.stringify({
        default: "fixture_backend_key_123456789012345",
      }),
    }),
    false,
  );
});
