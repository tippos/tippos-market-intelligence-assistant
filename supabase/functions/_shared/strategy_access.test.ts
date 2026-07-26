import {
  assertEquals,
  assertMatch,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  hasStrategyAccessCode,
  strategyAllowedOrigin,
  strategyClientHash,
} from "./strategy_access.ts";

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

Deno.test("accepts only the configured strategy access code", async () => {
  const digest = await sha256("high-entropy-fixture-code");
  const accepted = new Request("https://example.test", {
    headers: { "x-strategy-access-code": "high-entropy-fixture-code" },
  });
  const rejected = new Request("https://example.test", {
    headers: { "x-strategy-access-code": "wrong-code" },
  });
  assertEquals(await hasStrategyAccessCode(accepted, digest), true);
  assertEquals(await hasStrategyAccessCode(rejected, digest), false);
  assertEquals(await hasStrategyAccessCode(accepted, undefined), false);
});

Deno.test("restricts browser CORS to a configured HTTPS origin", () => {
  assertEquals(
    strategyAllowedOrigin("https://internal.example/path"),
    "https://internal.example",
  );
  assertEquals(
    strategyAllowedOrigin("http://internal.example"),
    "https://tippos.github.io",
  );
  assertEquals(strategyAllowedOrigin("not a URL"), "https://tippos.github.io");
});

Deno.test("hashes the client address with a deployment secret", async () => {
  const request = new Request("https://example.test", {
    headers: { "cf-connecting-ip": "203.0.113.9" },
  });
  const first = await strategyClientHash(
    request,
    "fixture-rate-limit-salt-with-32-bytes",
  );
  const second = await strategyClientHash(
    request,
    "different-fixture-rate-limit-salt-32",
  );
  assertMatch(first ?? "", /^[0-9a-f]{64}$/);
  assertNotEquals(first, second);
  assertEquals(first?.includes("203.0.113.9"), false);
});

Deno.test("disables browser access when rate-limit salt is missing", async () => {
  const request = new Request("https://example.test");
  assertEquals(await strategyClientHash(request, undefined), null);
});
