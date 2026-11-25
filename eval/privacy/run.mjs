// Privacy matrix runner: `npm run eval:privacy`. Local Supabase only.
// Prints and writes counts and outcome classes only — see report.mjs.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';
import { assertLocalTarget, buildReport, cell, resultsPath } from './report.mjs';
import { CREDENTIAL_KINDS, MALFORMED_TOKEN, expiredTokenFor, forgedTokenFor, headersFor, makeSigner } from './credentials.mjs';
import { newCanary, findLeaks } from './canary.mjs';
import { probeTables, ownerQuery } from './probes/tables.mjs';
import { probeFunctions } from './probes/functions.mjs';
import { probeLambdas } from './probes/lambdas.mjs';
import { probeSelf } from './probes/self.mjs';
import { rowFor, SEED_ORDER } from './fixtures.mjs';
import { envSecretsFrom, scanBundle, secretPatterns } from './bundle-scan.mjs';

const root = resolve(dirname(new URL(import.meta.url).pathname), '../..');
const env = process.env;
const required = ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'SUPABASE_SERVICE_ROLE_KEY'];
const missing = required.filter((name) => !env[name]?.trim());
if (!env.SUPABASE_JWT_SECRET?.trim() && !env.SUPABASE_JWT_SIGNING_JWK?.trim()) {
  missing.push('SUPABASE_JWT_SECRET or SUPABASE_JWT_SIGNING_JWK');
}
if (missing.length) {
  console.error(`privacy matrix: missing ${missing.join(', ')} (see eval/privacy/README.md)`);
  process.exit(2);
}
const url = assertLocalTarget(env.SUPABASE_URL).origin;
const anonKey = env.SUPABASE_ANON_KEY;
// Stacks with an asymmetric signing key reject the CLI's HS256 service key at
// the auth server, so the admin token is minted with the same key users get.
const signer = makeSigner({
  secret: env.SUPABASE_JWT_SECRET,
  jwk: env.SUPABASE_JWT_SIGNING_JWK ? JSON.parse(env.SUPABASE_JWT_SIGNING_JWK) : undefined,
});
const nowSeconds = Math.floor(Date.now() / 1000);
const adminToken = env.SUPABASE_JWT_SIGNING_JWK
  ? signer({ role: 'service_role', iss: 'supabase-demo', iat: nowSeconds, exp: nowSeconds + 3600 })
  : env.SUPABASE_SERVICE_ROLE_KEY;
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

const EMAIL = /^privacy-matrix-[0-9a-f]+@example\.test$/;

async function createUser(created) {
  const suffix = randomBytes(12).toString('hex');
  const email = `privacy-matrix-${suffix}@example.test`;
  const password = `Pm-${suffix}-Aa1!`;
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
    if (!/→ 404$/.test(error.message)) throw error; // already gone is fine
  }
}

// Test users left by this or any earlier run, found by their reserved email shape.
async function leftoverUsers() {
  const page = await call('/auth/v1/admin/users?per_page=1000');
  return (page.users ?? []).filter((u) => EMAIL.test(u.email ?? '')).map((u) => u.id);
}

async function seed(owner, canaries) {
  const insert = async (table, row) => (await call(`/rest/v1/${table}`, {
    method: 'POST', headers: { ...admin, prefer: 'return=representation' }, body: row,
  }))[0];
  const ctx = { userId: owner.id, marker: canaries.seed, unique: 'seed' };
  ctx.notebookId = (await insert('notebooks', rowFor('notebooks', { ...ctx, marker: canaries.notebook }))).id;
  for (const unique of ['a', 'b']) {
    await insert('entities', rowFor('entities', { ...ctx, unique, marker: unique === 'a' ? canaries.entity : 'Second fixture' }));
  }
  ctx.sessionId = rowFor('conversation_runtime_sessions', ctx).id;
  const unseeded = [];
  for (const table of SEED_ORDER.filter((t) => t !== 'notebooks' && t !== 'entities')) {
    try {
      await insert(table, rowFor(table, ctx));
    } catch {
      unseeded.push(table);
    }
  }
  return { ctx, unseeded };
}

function gitShortSha() {
  return execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root }).toString().trim();
}

const startedAt = new Date().toISOString();
const canaries = Object.fromEntries(['notebook', 'entity', 'seed'].map((k) => [k, newCanary(k)]));
const permanentKey = newCanary('permanent_key');
const created = [];
const cells = [];
const notes = {};
let cleanupFailed = false;

try {
  notes.leftoverUsersAtStart = (await leftoverUsers()).length;
  for (const id of await leftoverUsers()) await deleteUser(id);
  const a = await createUser(created);
  const b = await createUser(created);
  const c = await createUser(created);
  await deleteUser(c.id); // its token still verifies until it expires
  const { ctx, unseeded } = await seed(a, canaries);
  const notebookId = ctx.notebookId;
  notes.unseededTables = unseeded;
  notes.signing = env.SUPABASE_JWT_SIGNING_JWK ? 'ES256' : 'HS256';
  notes.functionsJwtGateway = env.PRIVACY_FUNCTIONS_JWT_GATEWAY ?? 'unknown';
  notes.migrationsHead = readdirSync(resolve(root, 'supabase/migrations')).sort().at(-1).replace(/\.sql$/, '');

  const now = new Date();
  const tokens = {
    owner: a.token, other_user: b.token, deleted_user: c.token, malformed: MALFORMED_TOKEN,
    expired: expiredTokenFor(a.id, signer, now), forged: forgedTokenFor(a.id, now),
  };
  const headersByKind = Object.fromEntries(CREDENTIAL_KINDS.map((k) => [k, headersFor(k, tokens, anonKey)]));
  const contentCanaries = Object.values(canaries);
  const owner = { userId: a.id, notebookId };

  cells.push(...await probeTables({
    url, kinds: CREDENTIAL_KINDS, headersByKind, owner, attackerId: b.id,
    markers: [a.id, notebookId, ...contentCanaries],
    rowFor: (table, unique) => rowFor(table, { ...ctx, unique }),
    snapshot: async (table) => JSON.stringify(await call(`/rest/v1/${table}?select=*&${ownerQuery(table, owner)}`)),
  }));
  cells.push(...await probeFunctions({
    url, kinds: CREDENTIAL_KINDS, headersByKind, notebookId,
    canaries: contentCanaries, internalSecret: env.EMBED_INTERNAL_SECRET ?? randomUUID(),
    ownerQueryText: canaries.entity, ownerMarkers: ['pm-entity-a'],
  }));
  cells.push(...await probeSelf({ url, headersByKind, ids: { owner: a.id, deleted_user: c.id } }));
  const lambdas = await probeLambdas({
    url, anonKey, kinds: CREDENTIAL_KINDS, headersByKind, notebookId,
    canaries: contentCanaries, permanentKey, entityCanary: canaries.entity,
  });
  cells.push(...lambdas.cells);

  // Log audit: nothing user-authored and no provider key may reach a log line.
  const logWatch = [...contentCanaries, permanentKey];
  cells.push(cell({
    surface: 'logs', target: 'lambdas', credential: 'all', operation: 'audit', expected: 'no_leak',
    observed: findLeaks(lambdas.logs, logWatch).length ? 'leak' : 'no_leak',
  }));
  const functionLog = env.PRIVACY_FUNCTION_LOG;
  cells.push(cell({
    surface: 'logs', target: 'functions', credential: 'all', operation: 'audit', expected: 'no_leak',
    observed: !functionLog || !existsSync(functionLog) ? 'error'
      : findLeaks([readFileSync(functionLog, 'utf8')], logWatch).length ? 'leak' : 'no_leak',
  }));

  // Shipped bundles: no provider or privileged secret on the client.
  const bundlePaths = (env.PRIVACY_BUNDLE_PATHS ?? 'build/web:dist:build/ios/iphoneos/Runner.app')
    .split(':').filter(Boolean).map((p) => resolve(root, p)).filter(existsSync);
  notes.bundlesScanned = bundlePaths.map((p) => relative(root, p) || '.');
  const dotenv = resolve(root, env.PRIVACY_DOTENV ?? '.env');
  const envSecrets = existsSync(dotenv) ? envSecretsFrom(readFileSync(dotenv, 'utf8')) : {};
  notes.envSecretsChecked = Object.keys(envSecrets);
  const findings = await scanBundle(bundlePaths, secretPatterns({ internalSecret: env.EMBED_INTERNAL_SECRET, envSecrets }));
  cells.push(cell({
    surface: 'bundle', target: 'client', credential: 'none', operation: 'secret_scan', expected: 'no_leak',
    observed: !bundlePaths.length ? 'error' : findings.length ? 'leak' : 'no_leak',
  }));
  notes.bundleFindings = findings.map((f) => `${relative(root, f.path)}:${f.pattern}`);
} catch (error) {
  // call() errors carry only method, path and status — safe for the report.
  notes.setupError = String(error?.message ?? error).slice(0, 200);
  cells.push(cell({ surface: 'run', target: 'setup', credential: 'none', operation: 'complete', expected: 'no_leak', observed: 'error' }));
} finally {
  for (const id of created.reverse()) {
    try { await deleteUser(id); } catch { cleanupFailed = true; }
  }
  try {
    if ((await leftoverUsers()).length) cleanupFailed = true;
  } catch {
    cleanupFailed = true;
  }
}

cells.push(cell({
  surface: 'run', target: 'test_users', credential: 'none', operation: 'cleanup', expected: 'no_leak', observed: cleanupFailed ? 'error' : 'no_leak',
}));
const commit = gitShortSha();
const report = buildReport({ commit, cells, startedAt, notes });
const out = resolve(root, resultsPath(new Date(startedAt), commit));
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, `${JSON.stringify(report, null, 2)}\n`);
const { total, passed, failed, controls, controlsPassed } = report.summary;
console.log(`privacy matrix: cells ${total}, passed ${passed}, failed ${failed}, controls ${controlsPassed}/${controls}`);
for (const c of cells.filter((x) => !x.pass)) {
  console.log(`  FAIL ${c.surface}/${c.target} ${c.credential} ${c.operation}: expected ${c.expected}, got ${c.observed}`);
}
console.log(`report: ${relative(root, out)}`);
process.exit(failed === 0 && controlsPassed === controls ? 0 : 1);
