// First-use study account, local Supabase only.
//   node eval/first-use/seed.mjs           create the study account with one empty notebook
//   node eval/first-use/seed.mjs --reset   delete the account and every row it owns,
//                                          then count what is left (must be 0; exit 1 if not)
// Needs the env from `source eval/privacy/local-env.sh`. Touches only
// first-use-study@example.test; never other users' data.
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { makeSigner } from '../privacy/credentials.mjs';

export const STUDY_EMAIL = 'first-use-study@example.test';
const LOOPBACK = new Set(['localhost', '127.0.0.1', '[::1]']);

export function assertLocal(url) {
  const parsed = new URL(url);
  if (!LOOPBACK.has(parsed.hostname)) throw new Error('the first-use seed runs against local Supabase only');
  return parsed.origin;
}

// Every table, children before parents, so deletes do not trip foreign keys.
const USER_TABLES = [
  'memory_fact_corrections', 'memory_facts', 'conversation_state', 'memory_backfill_progress', 'account_deletion_requests',
  'entity_embeddings', 'relations', 'conversation_turns', 'journal_entries', 'follow_ups', 'asked_questions',
  'session_cards', 'session_briefs', 'entity_suppressions', 'suppression_keys', 'forget_erase_jobs',
  'conversation_runtime_sessions', 'entities', 'notebooks', 'profiles',
];
const DELETE_ORDER = ['conversation_runtime_inbox', 'notebook_commit_requests', 'retrieve_rate_limits', ...USER_TABLES];

const inList = (values) => values.join(',');

// PostgREST filter selecting the study account's rows in each table; null
// when the table can hold none (its parent rows are already gone).
export function rowFilters({ userId, notebookIds, sessionIds }) {
  const scopes = [`user:${userId}`, ...notebookIds.map((id) => `notebook:${id}`)];
  return {
    ...Object.fromEntries(USER_TABLES.map((t) => [t, `user_id=eq.${userId}`])),
    conversation_runtime_inbox: sessionIds.length ? `session_id=in.(${inList(sessionIds)})` : null,
    // Cascades from forget_erase_jobs (no user_id of its own).
    forget_erase_batches: null,
    notebook_commit_requests: notebookIds.length ? `notebook_id=in.(${inList(notebookIds)})` : null,
    retrieve_rate_limits: `scope=in.(${scopes.map((s) => `"${s}"`).join(',')})`,
  };
}

export function remainingTotal(counts) {
  return Object.values(counts).reduce((sum, n) => sum + n, 0);
}

// The row the app itself inserts for a new user (SupabaseService.newNotebookRow).
export function emptyNotebookRow(userId, now) {
  return { user_id: userId, title: 'Untitled', started_at: now.toISOString(), conversation_mode: 'just_talk', mode_context: {} };
}

function client(env) {
  const missing = ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY'].filter((k) => !env[k]?.trim());
  if (missing.length) throw new Error(`missing ${missing.join(', ')}; run: source eval/privacy/local-env.sh`);
  const url = assertLocal(env.SUPABASE_URL);
  // Stacks with an asymmetric signing key reject the HS256 service key at the
  // auth server, so mint the admin token with the key users get (as the privacy matrix does).
  const now = Math.floor(Date.now() / 1000);
  const adminToken = env.SUPABASE_JWT_SIGNING_JWK
    ? makeSigner({ jwk: JSON.parse(env.SUPABASE_JWT_SIGNING_JWK) })({ role: 'service_role', iss: 'supabase-demo', iat: now, exp: now + 600 })
    : env.SUPABASE_SERVICE_ROLE_KEY;
  const headers = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, authorization: `Bearer ${adminToken}`, 'content-type': 'application/json' };

  async function call(path, { method = 'GET', body, extra = {} } = {}) {
    const response = await fetch(`${url}${path}`, {
      method, headers: { ...headers, ...extra }, body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${method} ${path.split('?')[0]} → ${response.status}`);
    return { response, data: text ? JSON.parse(text) : null };
  }
  return { call };
}

async function findStudyUser({ call }) {
  const { data } = await call('/auth/v1/admin/users?per_page=1000');
  return (data.users ?? []).find((u) => u.email === STUDY_EMAIL) ?? null;
}

async function idsOf({ call }, table, column, filter) {
  if (!filter) return [];
  const { data } = await call(`/rest/v1/${table}?select=${column}&${filter}`);
  return data.map((row) => row[column]);
}

async function count({ call }, table, filter) {
  if (!filter) return 0;
  const { response } = await call(`/rest/v1/${table}?select=*&${filter}`, { extra: { prefer: 'count=exact', range: '0-0' } });
  return Number(response.headers.get('content-range')?.split('/')[1] ?? NaN);
}

async function reset(api) {
  const user = await findStudyUser(api);
  // Remember the account's ids before deleting, so leftovers can still be found afterwards.
  const userId = user?.id ?? null;
  let filters = null;
  if (userId) {
    const notebookIds = await idsOf(api, 'notebooks', 'id', `user_id=eq.${userId}`);
    const sessionIds = await idsOf(api, 'conversation_runtime_sessions', 'id', `user_id=eq.${userId}`);
    filters = rowFilters({ userId, notebookIds, sessionIds });
    let failed = 0;
    for (const table of DELETE_ORDER) {
      if (!filters[table]) continue;
      try {
        await api.call(`/rest/v1/${table}?${filters[table]}`, { method: 'DELETE' });
      } catch (error) {
        failed += 1;
        console.error(`delete ${table}: ${error.message} (counted below)`);
      }
    }
    // Keep the account if anything failed: its id is how a rerun finds the leftovers.
    if (!failed) await api.call(`/auth/v1/admin/users/${userId}`, { method: 'DELETE' });
  }
  const counts = { authUser: (await findStudyUser(api)) ? 1 : 0 };
  for (const table of DELETE_ORDER) counts[table] = filters ? await count(api, table, filters[table]) : 0;
  for (const [name, n] of Object.entries(counts)) console.log(`${name.padEnd(30)} ${n}`);
  const total = remainingTotal(counts);
  console.log(`remaining rows for ${STUDY_EMAIL}: ${total}${userId ? '' : ' (no study account existed)'}`);
  return total;
}

async function seed(api, env) {
  if (await findStudyUser(api)) throw new Error('the study account already exists; run with --reset first');
  const password = env.FIRST_USE_PASSWORD?.trim() || `Fu-${randomBytes(9).toString('hex')}-Aa1!`;
  const { data: user } = await api.call('/auth/v1/admin/users', {
    method: 'POST', body: { email: STUDY_EMAIL, password, email_confirm: true },
  });
  await api.call('/rest/v1/notebooks', { method: 'POST', body: emptyNotebookRow(user.id, new Date()) });
  console.log(`study account ready: ${STUDY_EMAIL}, one empty notebook`);
  if (!env.FIRST_USE_PASSWORD?.trim()) console.log(`password (local test account only): ${password}`);
}

async function main() {
  const api = client(process.env);
  if (process.argv.includes('--reset')) {
    process.exit((await reset(api)) === 0 ? 0 : 1);
  }
  await seed(api, process.env);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`first-use seed: ${error.message}`);
    process.exit(1);
  });
}
