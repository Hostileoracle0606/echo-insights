import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { appleConfigFromEnv, type AppleConfig, makeClientSecret, revokeAppleAccess } from "./apple.ts";

const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));
const unb64url = (s: string) => {
  const p = s.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - (s.length % 4)) % 4);
  return Uint8Array.from(atob(p), (c) => c.charCodeAt(0));
};

async function throwawayConfig() {
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64(pkcs8).match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----`;
  const cfg: AppleConfig = { teamId: "TEAM123456", keyId: "KEY1234567", privateKeyPem: pem, clientId: "com.example.app" };
  return { cfg, publicKey: kp.publicKey };
}

type Rec = { url: string; method: string; contentType: string | null; form: URLSearchParams };
function fakeFetch(responses: Array<{ status: number; json?: unknown } | "throw">) {
  const calls: Rec[] = [];
  let i = 0;
  const f = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({
      url: String(url),
      method: init?.method ?? "GET",
      contentType: new Headers(init?.headers).get("content-type"),
      form: new URLSearchParams(String(init?.body ?? "")),
    });
    const r = responses[Math.min(i++, responses.length - 1)];
    if (r === "throw") throw new Error("network");
    return new Response(r.json === undefined ? "" : JSON.stringify(r.json), { status: r.status });
  }) as typeof fetch;
  return { f, calls };
}

Deno.test("client secret is an ES256 JWT with kid, iss=team, sub=client id, aud, exp<=iat+6mo", async () => {
  const { cfg, publicKey } = await throwawayConfig();
  const jwt = await makeClientSecret(cfg, 1_800_000_000);
  const [h, p, s] = jwt.split(".");
  const header = JSON.parse(new TextDecoder().decode(unb64url(h)));
  const claims = JSON.parse(new TextDecoder().decode(unb64url(p)));
  assertEquals(header, { alg: "ES256", kid: "KEY1234567", typ: "JWT" });
  assertEquals(claims.iss, "TEAM123456");
  assertEquals(claims.sub, "com.example.app");
  assertEquals(claims.aud, "https://appleid.apple.com");
  assertEquals(claims.iat, 1_800_000_000);
  assert(claims.exp > claims.iat && claims.exp <= claims.iat + 15777000);
  const sig = unb64url(s);
  assertEquals(sig.length, 64);
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    sig,
    new TextEncoder().encode(`${h}.${p}`),
  );
  assert(ok);
});

Deno.test("exchanges the code then revokes the refresh token; bodies are form-urlencoded", async () => {
  const { cfg } = await throwawayConfig();
  const { f, calls } = fakeFetch([
    { status: 200, json: { refresh_token: "RT-1", access_token: "AT-1" } },
    { status: 200 },
  ]);
  const ok = await revokeAppleAccess({ cfg, code: "CODE-1", fetch: f, now: () => 1_800_000_000_000 });
  assertEquals(ok, true);
  assertEquals(calls.length, 2);
  assertEquals(calls[0].url, "https://appleid.apple.com/auth/token");
  assertEquals(calls[0].method, "POST");
  assertEquals(calls[0].contentType, "application/x-www-form-urlencoded");
  assertEquals(calls[0].form.get("client_id"), "com.example.app");
  assertEquals(calls[0].form.get("code"), "CODE-1");
  assertEquals(calls[0].form.get("grant_type"), "authorization_code");
  assertEquals(calls[0].form.get("client_secret")!.split(".").length, 3);
  assertEquals(calls[1].url, "https://appleid.apple.com/auth/revoke");
  assertEquals(calls[1].contentType, "application/x-www-form-urlencoded");
  assertEquals(calls[1].form.get("client_id"), "com.example.app");
  assertEquals(calls[1].form.get("token"), "RT-1");
  assertEquals(calls[1].form.get("token_type_hint"), "refresh_token");
  assertEquals(calls[1].form.get("client_secret")!.split(".").length, 3);
});

Deno.test("token endpoint failure -> false, revoke not called", async () => {
  const { cfg } = await throwawayConfig();
  const { f, calls } = fakeFetch([{ status: 400, json: { error: "invalid_grant" } }]);
  assertEquals(await revokeAppleAccess({ cfg, code: "c", fetch: f, now: () => 1_800_000_000_000 }), false);
  assertEquals(calls.length, 1);
});

Deno.test("token response without refresh_token -> false, revoke not called", async () => {
  const { cfg } = await throwawayConfig();
  const { f, calls } = fakeFetch([{ status: 200, json: { access_token: "a" } }]);
  assertEquals(await revokeAppleAccess({ cfg, code: "c", fetch: f, now: () => 1_800_000_000_000 }), false);
  assertEquals(calls.length, 1);
});

Deno.test("revoke failure -> false", async () => {
  const { cfg } = await throwawayConfig();
  const { f } = fakeFetch([{ status: 200, json: { refresh_token: "r" } }, { status: 400, json: { error: "invalid_client" } }]);
  assertEquals(await revokeAppleAccess({ cfg, code: "c", fetch: f, now: () => 1_800_000_000_000 }), false);
});

Deno.test("baseUrl override is used", async () => {
  const { cfg } = await throwawayConfig();
  const { f, calls } = fakeFetch([{ status: 200, json: { refresh_token: "r" } }, { status: 200 }]);
  await revokeAppleAccess({ cfg, code: "c", fetch: f, now: () => 1_800_000_000_000, baseUrl: "http://stub" });
  assertEquals(calls[0].url, "http://stub/auth/token");
});

Deno.test("appleConfigFromEnv: complete -> config; any missing -> null", () => {
  const full: Record<string, string> = {
    APPLE_TEAM_ID: "T",
    APPLE_KEY_ID: "K",
    APPLE_PRIVATE_KEY: "P",
    APPLE_CLIENT_ID: "C",
  };
  const env = (m: Record<string, string>) => ({ get: (k: string) => m[k] });
  assertEquals(appleConfigFromEnv(env(full)), { teamId: "T", keyId: "K", privateKeyPem: "P", clientId: "C" });
  for (const k of Object.keys(full)) {
    const { [k]: _omit, ...rest } = full;
    assertEquals(appleConfigFromEnv(env(rest)), null);
    assertEquals(appleConfigFromEnv(env({ ...full, [k]: "" })), null);
  }
});

Deno.test("appleConfigFromEnv: literal \\n in PEM is normalized", () => {
  const env = { get: (k: string) => ({ APPLE_TEAM_ID: "T", APPLE_KEY_ID: "K", APPLE_CLIENT_ID: "C", APPLE_PRIVATE_KEY: "a\\nb" } as Record<string, string>)[k] };
  assertEquals(appleConfigFromEnv(env)!.privateKeyPem, "a\nb");
});
