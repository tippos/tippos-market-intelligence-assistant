export type SearchConsoleRow = {
  keys?: unknown[];
  clicks?: unknown;
  impressions?: unknown;
  ctr?: unknown;
  position?: unknown;
};

export type SearchConsoleDateWindow = { startDate: string; endDate: string };

export function finalizedSearchConsoleWindow(
  now = new Date(),
  delayDays = 2,
  lookbackDays = 3,
): SearchConsoleDateWindow {
  if (!Number.isInteger(delayDays) || delayDays < 1 || delayDays > 7) {
    throw new Error("invalid_gsc_delay");
  }
  if (
    !Number.isInteger(lookbackDays) || lookbackDays < 1 || lookbackDays > 31
  ) throw new Error("invalid_gsc_lookback");
  const today = Date.UTC(
    now.getUTCFullYear(),
    now.getUTCMonth(),
    now.getUTCDate(),
  );
  const end = new Date(today - delayDays * 86_400_000);
  const start = new Date(end.getTime() - (lookbackDays - 1) * 86_400_000);
  return {
    startDate: start.toISOString().slice(0, 10),
    endDate: end.toISOString().slice(0, 10),
  };
}

export function inferQueryLanguage(query: string): string {
  if (/\p{Script=Hebrew}/u.test(query)) return "he";
  if (/\p{Script=Arabic}/u.test(query)) return "ar";
  if (/[\p{Script=Hiragana}\p{Script=Katakana}]/u.test(query)) return "ja";
  return "und";
}

export function mapSearchConsoleRows(rows: SearchConsoleRow[], offset = 0) {
  return rows.map((row, index) => {
    const keys = Array.isArray(row.keys) ? row.keys.map(String) : [];
    if (keys.length !== 3) throw new Error("invalid_search_console_row");
    const [date, query, deviceRaw] = keys;
    const device = deviceRaw.toLowerCase();
    if (
      !/^\d{4}-\d{2}-\d{2}$/.test(date) || !query ||
      !["desktop", "mobile", "tablet"].includes(device)
    ) {
      throw new Error("invalid_search_console_row");
    }
    return {
      query,
      language_code: inferQueryLanguage(query),
      observed_on: date,
      event_at: `${date}T12:00:00-08:00`,
      granularity: "day" as const,
      device: device as "desktop" | "mobile" | "tablet",
      impressions: Number(row.impressions ?? 0),
      clicks: Number(row.clicks ?? 0),
      ctr: Number(row.ctr ?? 0),
      average_position: Number(row.position ?? 0),
      confidence: 0.95,
      external_id: `gsc-${date}-${offset + index}`,
      intent: "unknown" as const,
      funnel_stage: "unknown" as const,
    };
  });
}

function base64Url(data: Uint8Array | string): string {
  const bytes = typeof data === "string"
    ? new TextEncoder().encode(data)
    : data;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(
    /=+$/g,
    "",
  );
}

export async function createServiceAccountAssertion(
  clientEmail: string,
  privateKeyPem: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<string> {
  if (!/^\S+@\S+$/.test(clientEmail)) {
    throw new Error("invalid_gsc_client_email");
  }
  const clean = privateKeyPem.replace(/\\n/g, "\n").replace(
    /-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,
    "",
  );
  if (!clean) throw new Error("invalid_gsc_private_key");
  const der = Uint8Array.from(atob(clean), (char) => char.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const header = base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = base64Url(JSON.stringify({
    iss: clientEmail,
    scope: "https://www.googleapis.com/auth/webmasters.readonly",
    aud: "https://oauth2.googleapis.com/token",
    iat: nowSeconds,
    exp: nowSeconds + 3600,
  }));
  const signingInput = `${header}.${claim}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}
