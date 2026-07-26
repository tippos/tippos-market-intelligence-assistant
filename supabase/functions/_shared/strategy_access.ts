const DEFAULT_ALLOWED_ORIGIN = "https://tippos.github.io";
const SHA256_HEX = /^[0-9a-f]{64}$/;

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

export function strategyAllowedOrigin(
  configured = Deno.env.get("STRATEGY_ALLOWED_ORIGIN")?.trim(),
): string {
  if (!configured) return DEFAULT_ALLOWED_ORIGIN;
  try {
    const url = new URL(configured);
    return url.protocol === "https:" ? url.origin : DEFAULT_ALLOWED_ORIGIN;
  } catch {
    return DEFAULT_ALLOWED_ORIGIN;
  }
}

export async function hasStrategyAccessCode(
  req: Request,
  expectedDigest = Deno.env.get("STRATEGY_ACCESS_CODE_SHA256")?.trim()
    .toLowerCase(),
): Promise<boolean> {
  const code = req.headers.get("x-strategy-access-code")?.trim();
  if (
    !code || code.length > 200 || !expectedDigest ||
    !SHA256_HEX.test(expectedDigest)
  ) {
    return false;
  }
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(code),
  );
  const actualDigest = hex(digest);
  let difference = 0;
  for (let index = 0; index < actualDigest.length; index += 1) {
    difference |= actualDigest.charCodeAt(index) ^
      expectedDigest.charCodeAt(index);
  }
  return difference === 0;
}

export async function strategyClientHash(
  req: Request,
  salt = Deno.env.get("STRATEGY_RATE_LIMIT_SALT")?.trim(),
): Promise<string | null> {
  if (!salt || salt.length < 32 || salt.length > 500) return null;
  const address = (
    req.headers.get("cf-connecting-ip") ??
      req.headers.get("x-real-ip") ??
      req.headers.get("x-forwarded-for")?.split(",", 1)[0] ??
      "unknown"
  ).trim().toLowerCase().slice(0, 200);
  if (!address) return null;
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${salt}:${address}`),
  );
  return hex(digest);
}
