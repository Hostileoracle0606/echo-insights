// The local Supabase stack, as the recovery eval uses it: admin REST calls and
// throwaway `recovery-eval-*@example.test` users. Never a hosted project.
// Env comes from `source eval/privacy/local-env.sh`.
import { randomBytes } from 'node:crypto';
import { assertLocalTarget } from '../privacy/report.mjs';
import { makeSigner } from '../privacy/credentials.mjs';

export const EVAL_EMAIL = /^recovery-eval-[0-9a-f]+@example\.test$/;

// null when the stack's env is not set (unit-only test runs skip on it).
export function localStack(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY || !env.SUPABASE_SERVICE_ROLE_KEY) return null;
  const url = assertLocalTarget(env.SUPABASE_URL).origin;
  const anonKey = env.SUPABASE_ANON_KEY;
  // Stacks with an asymmetric signing key reject the CLI's HS256 service key
  // at the auth server, so the admin token is minted with the users' key.
  let adminToken = env.SUPABASE_SERVICE_ROLE_KEY;
  if (env.SUPABASE_JWT_SIGNING_JWK) {
    const signer = makeSigner({ jwk: JSON.parse(env.SUPABASE_JWT_SIGNING_JWK) });
    const now = Math.floor(Date.now() / 1000);
    adminToken = signer({ role: 'service_role', iss: 'supabase-demo', iat: now, exp: now + 6 * 3600 });
  }
  const admin = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, authorization: `Bearer ${adminToken}`, 'content-type': 'application/json' };

  async function call(path, { method = 'GET', headers = admin, body } = {}) {
    const response = await fetch(`${url}${path}`, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${method} ${path.split('?')[0]} → ${response.status}`);
    return text ? JSON.parse(text) : null;
  }

  const insert = async (table, row) => (await call(`/rest/v1/${table}`, {
    method: 'POST', headers: { ...admin, prefer: 'return=representation' }, body: row,
  }))[0];

  async function createUser(created = []) {
    const suffix = randomBytes(12).toString('hex');
    const email = `recovery-eval-${suffix}@example.test`;
    const password = `Re-${suffix}-Aa1!`;
    const user = await call('/auth/v1/admin/users', { method: 'POST', body: { email, password, email_confirm: true } });
    created.push(user.id); // before sign-in, so a failed sign-in can't orphan it
    const session = await call('/auth/v1/token?grant_type=password', {
      method: 'POST', headers: { apikey: anonKey, 'content-type': 'application/json' }, body: { email, password },
    });
    return { id: user.id, token: session.access_token };
  }

  async function deleteUser(id) {
    try {
      await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE' });
    } catch (error) {
      if (!/→ 404$/.test(error.message)) throw error;
    }
  }

  async function leftoverUsers() {
    const page = await call('/auth/v1/admin/users?per_page=1000');
    return (page.users ?? []).filter((u) => EVAL_EMAIL.test(u.email ?? '')).map((u) => u.id);
  }

  async function sweep() {
    const ids = await leftoverUsers();
    for (const id of ids) await deleteUser(id);
    return ids.length;
  }

  return { url, anonKey, admin, call, insert, createUser, deleteUser, leftoverUsers, sweep };
}
