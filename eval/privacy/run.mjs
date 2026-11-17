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

async function createUser() {
  const suffix = randomBytes(12).toString('hex');
  const email = `privacy-matrix-${suffix}@example.test`;
  const password = `Pm-${suffix}-Aa1!`;
  const user = await call('/auth/v1/admin/users', { method: 'POST', body: { email, password, email_confirm: true } });
  const session = await call('/auth/v1/token?grant_type=password', {
    method: 'POST', headers: { apikey: anonKey, 'content-type': 'application/json' }, body: { email, password },
  });
  return { id: user.id, token: session.access_token };
}

const deleteUser = (id) => call(`/auth/v1/admin/users/${id}`, { method: 'DELETE' });

async function seed(owner, canaries) {
  const now = new Date().toISOString();
  const [notebook] = await call('/rest/v1/notebooks', {
    method: 'POST', headers: { ...admin, prefer: 'return=representation' },
    body: { user_id: owner.id, title: canaries.notebook, started_at: now },
  });
  const notebookId = notebook.id;
  const base = { user_id: owner.id, notebook_id: notebookId };
  const rows = {
    entities: [
      { ...base, id: 'pm-entity-a', name: canaries.entity, type: 'project', first_seen: now, last_seen: now },
      { ...base, id: 'pm-entity-b', name: 'Second fixture', type: 'person', first_seen: now, last_seen: now },
    ],
    relations: [{ ...base, id: 'pm-relation', source_id: 'pm-entity-a', target_id: 'pm-entity-b', label: canaries.relation }],
    journal_entries: [{ ...base, text: canaries.entry, created_at: now }],
    conversation_turns: [{ ...base, turn_id: 'pm-turn', speaker: 'user', text: canaries.turn, spoken_at: now }],
    follow_ups: [{ ...base, question: canaries.follow_up }],
    asked_questions: [{ ...base, question: canaries.asked }],
    session_cards: [{ ...base, conversation_mode: 'just_talk', source_revision: 1, card: { note: canaries.card } }],
  };
  const seeded = new Set(['notebooks', 'profiles']);
  const unseeded = [];
  for (const [table, values] of Object.entries(rows)) {
    try {
      await call(`/rest/v1/${table}`, { method: 'POST', body: values });
      seeded.add(table);
    } catch {
      unseeded.push(table);
    }
  }
  return { notebookId, seeded, unseeded };
}

function gitShortSha() {
  return execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root }).toString().trim();
}

const startedAt = new Date().toISOString();
const canaries = Object.fromEntries(
  ['notebook', 'entity', 'relation', 'entry', 'turn', 'follow_up', 'asked', 'card'].map((k) => [k, newCanary(k)]));
const permanentKey = newCanary('permanent_key');
const created = [];
const cells = [];
const notes = {};
let cleanupFailed = false;

try {
  const a = await createUser(); created.push(a.id);
  const b = await createUser(); created.push(b.id);
  const c = await createUser();
  await deleteUser(c.id); // its token still verifies until it expires
  const { notebookId, seeded, unseeded } = await seed(a, canaries);
  notes.unseededTables = unseeded;
  notes.signing = env.SUPABASE_JWT_SIGNING_JWK ? 'ES256' : 'HS256';
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
    url, kinds: CREDENTIAL_KINDS, headersByKind, owner, seededTables: seeded,
    markers: [a.id, notebookId, ...contentCanaries],
    snapshot: async (table) => JSON.stringify(await call(`/rest/v1/${table}?select=*&${ownerQuery(table, owner)}`)),
  }));
  cells.push(...await probeFunctions({
    url, kinds: CREDENTIAL_KINDS, headersByKind, notebookId,
    canaries: contentCanaries, internalSecret: env.EMBED_INTERNAL_SECRET ?? randomUUID(),
  }));
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
