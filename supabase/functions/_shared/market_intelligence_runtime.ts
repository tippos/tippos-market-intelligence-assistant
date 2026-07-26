import { createClient } from "npm:@supabase/supabase-js@2.110.6";

type BackendAuthConfig = {
  secretKeysJson?: string;
  legacyServiceRoleKey?: string;
  customIngestKey?: string;
};

function configuredSecretKeys(raw: string | undefined): string[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    return Object.values(parsed).filter((value): value is string =>
      typeof value === "string" && value.length > 20
    );
  } catch {
    return [];
  }
}

async function secureEqual(left: string, right: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const aa = new Uint8Array(a);
  const bb = new Uint8Array(b);
  let diff = 0;
  for (let index = 0; index < aa.length; index += 1) {
    diff |= aa[index] ^ bb[index];
  }
  return diff === 0;
}

async function hasConfiguredAccess(
  req: Request,
  config: BackendAuthConfig,
  includeCustomIngestKey: boolean,
): Promise<boolean> {
  const bearer = (req.headers.get("authorization") ?? "").replace(
    /^Bearer\s+/i,
    "",
  ).trim();
  const provided = (req.headers.get("apikey") ?? bearer).trim();
  if (!provided) return false;
  const candidates = [
    ...configuredSecretKeys(config.secretKeysJson),
    config.legacyServiceRoleKey,
    includeCustomIngestKey ? config.customIngestKey : undefined,
  ].filter((value): value is string =>
    typeof value === "string" && value.length > 20
  );
  for (const candidate of candidates) {
    if (await secureEqual(candidate, provided)) return true;
  }
  return false;
}

function environmentAuthConfig(): BackendAuthConfig {
  return {
    secretKeysJson: Deno.env.get("SUPABASE_SECRET_KEYS"),
    legacyServiceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
    customIngestKey: Deno.env.get("MARKET_INTELLIGENCE_INGEST_KEY"),
  };
}

export function hasBackendAccess(
  req: Request,
  supplied = environmentAuthConfig(),
): Promise<boolean> {
  return hasConfiguredAccess(req, supplied, false);
}

export function hasIngestAccess(
  req: Request,
  supplied = environmentAuthConfig(),
): Promise<boolean> {
  return hasConfiguredAccess(req, supplied, true);
}

export function adminClient() {
  const url = Deno.env.get("SUPABASE_URL");
  const service =
    configuredSecretKeys(Deno.env.get("SUPABASE_SECRET_KEYS"))[0] ??
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !service) throw new Error("service_role_misconfigured");
  return createClient(url, service, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
