// Server-side retrieval latency: retrieve-memory at user scope (the lookup a
// live turn waits on) against the local stack, as a seeded timing user.
// No Gemini spend: retrieval embeds with local gte-small.
//
//   source eval/privacy/local-env.sh; source <file exporting TIMING_USER_PASSWORD>
//   node eval/timing/retrieval.mjs --email timing-eval-…@example.test --size 50 [--runs 50] [--warmup 5]
//
// Writes retrieval-<size>.jsonl (one `[lumen-timing]` span per call, warm-up
// discarded) into eval/results/<date>-<sha>/timing/. A refused or failed call
// is kept with ok:false, never retried away.
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { PREFIX } from './parse.mjs';
import { isTimingEmail, vocabularyName } from './seed.mjs';

const USER_SCOPE = 1; // RetrievalScope.user.index in the app
const USER_PER_MIN = 30;
const NOTEBOOK_PER_MIN = 20;

/** Milliseconds between calls, rotating over [notebooks], under both limits. */
export function paceMs(notebooks) {
  const perUser = 60_000 / USER_PER_MIN;
  const perNotebook = 60_000 / (NOTEBOOK_PER_MIN * Math.max(1, notebooks));
  return Math.ceil(Math.max(perUser, perNotebook) * 1.05);
}

/** Synthetic queries: seeded vocabulary, sometimes paired, sometimes absent. */
export function queryFor(i) {
  const forms = [
    () => vocabularyName(i * 7),
    () => `what about ${vocabularyName(i * 13)}`,
    () => `${vocabularyName(i * 3)} and ${vocabularyName(i * 11 + 1)}`,
    () => 'anything new this week',
  ];
  return forms[i % forms.length]();
}

export function retrievalLine({ tMs, durMs, count, ok, size }) {
  return `${PREFIX} ${JSON.stringify({
    v: 1, stage: 'retrieval_server', phase: 'span', t_ms: Math.round(tMs), dur_ms: Math.round(durMs),
    mode: 'node', scope: USER_SCOPE, count, ok, size,
  })}`;
}

async function main() {
  const { localStack } = await import('./local.mjs');
  const { entityCountBucket } = await import('./buckets.mjs');
  const { values } = parseArgs({ options: {
    email: { type: 'string' }, size: { type: 'string' }, runs: { type: 'string', default: '50' },
    warmup: { type: 'string', default: '5' },
  } });
  if (!isTimingEmail(values.email)) throw new Error('--email must be a timing-eval-*@example.test user');
  const size = Number(values.size);
  const runs = Number(values.runs);
  const warmup = Number(values.warmup);
  const password = process.env.TIMING_USER_PASSWORD;
  if (!password) throw new Error('set TIMING_USER_PASSWORD');

  const stack = localStack();
  const user = await stack.signIn(values.email, password);
  const headers = { apikey: stack.anonKey, authorization: `Bearer ${user.token}`, 'content-type': 'application/json' };
  const notebooks = (await stack.call('/rest/v1/notebooks?select=id&order=started_at.desc', { headers })).map((n) => n.id);
  if (!notebooks.length) throw new Error('timing user has no notebooks; run seed.mjs first');
  const entities = (await stack.call('/rest/v1/entities?select=id', { headers })).length;
  if (entities !== size) throw new Error(`seeded history has ${entities} entities, not ${size}`);

  const pace = paceMs(notebooks.length);
  const lines = [];
  const started = performance.now();
  for (let i = 0; i < warmup + runs; i++) {
    const tick = performance.now();
    const t0 = performance.now();
    let ok = false;
    let count = 0;
    try {
      const response = await fetch(`${stack.url}/functions/v1/retrieve-memory`, {
        method: 'POST', headers, signal: AbortSignal.timeout(30_000),
        body: JSON.stringify({ query: queryFor(i), notebookId: notebooks[i % notebooks.length], scope: 'user' }),
      });
      const body = await response.json().catch(() => null);
      ok = response.ok && Array.isArray(body?.entityIds);
      count = ok ? body.entityIds.length : 0;
    } catch {
      ok = false;
    }
    const t1 = performance.now();
    if (i >= warmup) {
      lines.push(retrievalLine({ tMs: t1 - started, durMs: t1 - t0, count, ok, size: entityCountBucket(size) }));
    }
    const wait = pace - (performance.now() - tick);
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  }

  const root = resolve(dirname(new URL(import.meta.url).pathname), '../..');
  const sha = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root }).toString().trim();
  const dir = resolve(root, `eval/results/${new Date().toISOString().slice(0, 10)}-${sha}/timing`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(resolve(dir, `retrieval-${size}.jsonl`), `${lines.join('\n')}\n`);
  const failed = lines.filter((l) => l.includes('"ok":false')).length;
  console.log(`retrieval ${size}: ${lines.length} calls, ${failed} failed`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().catch((error) => {
    console.error(`retrieval failed: ${error.message}`);
    process.exit(1);
  });
}
