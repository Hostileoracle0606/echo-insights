// The local Supabase stack, as the timing eval talks to it. Loopback only:
// source eval/privacy/local-env.sh first. Never a hosted project.
import { assertLocalTarget } from '../privacy/report.mjs';
import { makeSigner } from '../privacy/credentials.mjs';

export function localStack(env = process.env) {
  const missing = ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY'].filter((k) => !env[k]?.trim());
  if (missing.length) throw new Error(`timing eval: missing ${missing.join(', ')} (source eval/privacy/local-env.sh)`);
  const url = assertLocalTarget(env.SUPABASE_URL).origin;
  const anonKey = env.SUPABASE_ANON_KEY;
  let adminToken = env.SUPABASE_SERVICE_ROLE_KEY;
  if (env.SUPABASE_JWT_SIGNING_JWK) {
    const sign = makeSigner({ jwk: JSON.parse(env.SUPABASE_JWT_SIGNING_JWK) });
    const now = Math.floor(Date.now() / 1000);
    adminToken = sign({ role: 'service_role', iss: 'supabase-demo', iat: now, exp: now + 3600 });
  }
  const admin = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, authorization: `Bearer ${adminToken}`, 'content-type': 'application/json' };

  async function call(path, { method = 'GET', headers = admin, body } = {}) {
    const response = await fetch(`${url}${path}`, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${method} ${path.split('?')[0]} → ${response.status}`);
    return text ? JSON.parse(text) : null;
  }

  async function signIn(email, password) {
    const session = await call('/auth/v1/token?grant_type=password', {
      method: 'POST', headers: { apikey: anonKey, 'content-type': 'application/json' }, body: { email, password },
    });
    return { id: session.user.id, token: session.access_token };
  }

  return { url, anonKey, admin, call, signIn };
}
