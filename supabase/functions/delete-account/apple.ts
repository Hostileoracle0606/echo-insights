// Sign in with Apple token revocation. Never log the code, the client secret,
// a token, or any Apple response body.

export interface AppleConfig {
  teamId: string;
  keyId: string;
  privateKeyPem: string;
  clientId: string;
}

const APPLE = "https://appleid.apple.com";
const SECRET_LIFETIME_SEC = 5 * 60; // short-lived; Apple allows up to 6 months

export function appleConfigFromEnv(env: { get(k: string): string | undefined }): AppleConfig | null {
  const teamId = env.get("APPLE_TEAM_ID");
  const keyId = env.get("APPLE_KEY_ID");
  const pem = env.get("APPLE_PRIVATE_KEY");
  const clientId = env.get("APPLE_CLIENT_ID");
  if (!teamId || !keyId || !pem || !clientId) return null;
  // Secrets set from env files often carry literal "\n" sequences.
  return { teamId, keyId, privateKeyPem: pem.replaceAll("\\n", "\n"), clientId };
}

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
const enc = (o: unknown) => b64url(new TextEncoder().encode(JSON.stringify(o)));

export async function makeClientSecret(cfg: AppleConfig, nowSec: number): Promise<string> {
  const der = cfg.privateKeyPem
    .replace(/-----BEGIN [A-Z ]+-----/, "")
    .replace(/-----END [A-Z ]+-----/, "")
    .replace(/\s+/g, "");
  const keyBytes = Uint8Array.from(atob(der), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signingInput = `${enc({ alg: "ES256", kid: cfg.keyId, typ: "JWT" })}.${
    enc({
      iss: cfg.teamId,
      iat: nowSec,
      exp: nowSec + SECRET_LIFETIME_SEC,
      aud: APPLE,
      sub: cfg.clientId,
    })
  }`;
  // Web Crypto returns the raw r||s form that JWS ES256 requires.
  const sig = new Uint8Array(
    await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput)),
  );
  return `${signingInput}.${b64url(sig)}`;
}

const form = (o: Record<string, string>) => ({
  method: "POST",
  headers: { "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams(o).toString(),
});

/** Exchange the code for a refresh token, then revoke it. True on 2xx both. */
export async function revokeAppleAccess(p: {
  cfg: AppleConfig;
  code: string;
  fetch: typeof fetch;
  now: () => number; // ms
  baseUrl?: string;
}): Promise<boolean> {
  const base = p.baseUrl ?? APPLE;
  const secret = await makeClientSecret(p.cfg, Math.floor(p.now() / 1000));

  const tokenRes = await p.fetch(
    `${base}/auth/token`,
    form({ client_id: p.cfg.clientId, client_secret: secret, code: p.code, grant_type: "authorization_code" }),
  );
  if (!tokenRes.ok) {
    await tokenRes.body?.cancel();
    return false;
  }
  let refresh: unknown;
  try {
    refresh = (await tokenRes.json())?.refresh_token;
  } catch {
    return false;
  }
  if (typeof refresh !== "string" || !refresh) return false;

  const revokeRes = await p.fetch(
    `${base}/auth/revoke`,
    form({
      client_id: p.cfg.clientId,
      client_secret: secret,
      token: refresh,
      token_type_hint: "refresh_token",
    }),
  );
  await revokeRes.body?.cancel();
  return revokeRes.ok;
}
