import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  createServiceAccountAssertion,
  finalizedSearchConsoleWindow,
  inferQueryLanguage,
  mapSearchConsoleRows,
} from "./google_search_console.ts";

Deno.test("builds an overlapping finalized-data collection window", () => {
  assertEquals(finalizedSearchConsoleWindow(new Date("2026-07-23T23:59:59Z")), {
    startDate: "2026-07-19",
    endDate: "2026-07-21",
  });
  assertThrows(() => finalizedSearchConsoleWindow(new Date(), 0, 3));
  assertThrows(() => finalizedSearchConsoleWindow(new Date(), 2, 32));
});

Deno.test("detects non-Latin query scripts without guessing Latin languages", () => {
  assertEquals(inferQueryLanguage("טיפ דיגיטלי"), "he");
  assertEquals(inferQueryLanguage("بقشيش رقمي"), "ar");
  assertEquals(inferQueryLanguage("デジタルチップ"), "ja");
  assertEquals(inferQueryLanguage("digital tipping"), "und");
  assertEquals(inferQueryLanguage("propinas digitales"), "und");
});

Deno.test("maps official Search Analytics row dimensions", () => {
  const [row] = mapSearchConsoleRows([{
    keys: ["2026-07-01", "טיפ דיגיטלי", "MOBILE"],
    clicks: 4,
    impressions: 20,
    ctr: 0.2,
    position: 3.5,
  }]);
  assertEquals(row.language_code, "he");
  assertEquals(row.device, "mobile");
  assertEquals(row.average_position, 3.5);
});

Deno.test("rejects malformed Search Analytics dimensions", () => {
  assertThrows(() => mapSearchConsoleRows([{ keys: ["2026-07-01", "query"] }]));
});

Deno.test("creates a signed service-account OAuth assertion", async () => {
  const pair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const der = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );
  let binary = "";
  for (const byte of der) binary += String.fromCharCode(byte);
  const base64 = btoa(binary).match(/.{1,64}/g)?.join("\n") ?? "";
  const pem =
    `-----BEGIN PRIVATE KEY-----\n${base64}\n-----END PRIVATE KEY-----`;
  const assertion = await createServiceAccountAssertion(
    "service@example.test",
    pem,
    1_700_000_000,
  );
  assertEquals(assertion.split(".").length, 3);
});
