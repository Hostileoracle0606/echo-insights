// The local Supabase stack the memory eval runs against: admin headers, and
// throwaway users with a reserved email shape so leftovers can be swept.
// Refuses anything but a loopback URL (assertLocalTarget).
import { randomBytes } from 'node:crypto';
import { assertLocalTarget } from '../privacy/report.mjs';
import { makeSigner } from '../privacy/credentials.mjs';

export const TEST_EMAIL = /^memory-eval-[0-9a-f]+@example\.test$/;

// 502/503/504: the local gateway or auth server timed out; worth another try.
const TRANSIENT = new Set([502, 503, 504]);

export function localStack(env, {
  fetchImpl = fetch, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
} = {}) {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY || !env.SUPABASE_SERVICE_ROLE_KEY) return null;
  if (!env.SUPABASE_JWT_SECRET && !env.SUPABASE_JWT_SIGNING_JWK) return null;
  const url = assertLocalTarget(env.SUPABASE_URL).origin;
  const anonKey = env.SUPABASE_ANON_KEY;
  // Stacks with an asymmetric signing key reject the CLI's HS256 service key
  // at the auth server, so the admin token is minted with the users' key.
  const signer = makeSigner({
    secret: env.SUPABASE_JWT_SECRET,
    jwk: env.SUPABASE_JWT_SIGNING_JWK ? JSON.parse(env.SUPABASE_JWT_SIGNING_JWK) : undefined,
  });
  const adminToken = () => {
    if (!env.SUPABASE_JWT_SIGNING_JWK) return env.SUPABASE_SERVICE_ROLE_KEY;
    const now = Math.floor(Date.now() / 1000);
    return signer({ role: 'service_role', iss: 'supabase-demo', iat: now, exp: now + 3600 });
  };
  const adminHeaders = {
    apikey: env.SUPABASE_SERVICE_ROLE_KEY,
    authorization: `Bearer ${adminToken()}`,
    'content-type': 'application/json',
  };

  async function call(path, { method = 'GET', headers = adminHeaders, body } = {}) {
    const response = await fetchImpl(`${url}${path}`, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${method} ${path.split('?')[0]} → ${response.status}`);
    return text ? JSON.parse(text) : null;
  }

  async function createUser(created) {
    const suffix = randomBytes(12).toString('hex');
    const email = `memory-eval-${suffix}@example.test`;
    const password = `Me-${suffix}-Aa1!`;
    const user = await call('/auth/v1/admin/users', { method: 'POST', body: { email, password, email_confirm: true } });
    created.push(user.id); // before sign-in, so a failed sign-in can't orphan it
    const session = await call('/auth/v1/token?grant_type=password', {
      method: 'POST', headers: { apikey: anonKey, 'content-type': 'application/json' }, body: { email, password },
    });
    return { id: user.id, token: session.access_token };
  }

  // Idempotent, so a transient timeout is retried (1, 2, 4, 8 s); 404 = gone.
  async function deleteUser(id) {
    for (let attempt = 1; ; attempt += 1) {
      try {
        await call(`/auth/v1/admin/users/${id}`, { method: 'DELETE' });
        return;
      } catch (error) {
        if (/→ 404$/.test(error.message)) return;
        const status = Number(/→ (\d+)$/.exec(error.message)?.[1]);
        if (!TRANSIENT.has(status) || attempt >= 5) throw error;
        await sleep(1000 * 2 ** (attempt - 1));
      }
    }
  }

  // Only this suite's users: other sessions share the stack.
  async function sweep() {
    const page = await call('/auth/v1/admin/users?per_page=1000');
    const ids = (page.users ?? []).filter((u) => TEST_EMAIL.test(u.email ?? '')).map((u) => u.id);
    for (const id of ids) await deleteUser(id);
    return ids.length;
  }

  return { url, anonKey, admin: { url, adminHeaders }, call, createUser, deleteUser, sweep };
}

/**
 * Runs `work` as a fresh throwaway user and deletes the user after. If the
 * work succeeded and only the delete failed (after deleteUser's retries), the
 * work is kept and the user is reported in `leftover` for the end-of-run
 * sweep; a work error is rethrown after the cleanup attempt.
 */
export async function withUser(stack, work) {
  const created = [];
  let value;
  let workError = null;
  try {
    value = await work(await stack.createUser(created));
  } catch (error) {
    workError = error;
  }
  const leftover = [];
  for (const id of created) {
    try {
      await stack.deleteUser(id);
    } catch {
      leftover.push(id);
    }
  }
  if (workError) throw workError;
  return { value, leftover };
}
