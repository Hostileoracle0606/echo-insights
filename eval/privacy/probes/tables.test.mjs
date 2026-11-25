import { readdirSync, readFileSync } from 'node:fs';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { USER_TABLES, OWNER_READABLE, expectedFor, classifySelect, classifyWrite, probeTables } from './tables.mjs';

const A = { userId: 'aaaaaaaa-0000-4000-8000-000000000001', notebookId: 'bbbbbbbb-0000-4000-8000-000000000002' };

// Every public table the migrations create is probed, or excluded here with a reason.
const NOT_PROBED = {
  forget_erase_batches: 'child of forget_erase_jobs with no user column; server-only, reached only through its job',
};

test('covers every public table the migrations create', () => {
  const dir = new URL('../../../supabase/migrations/', import.meta.url);
  const created = new Set();
  for (const file of readdirSync(dir)) {
    for (const m of readFileSync(new URL(file, dir), 'utf8').matchAll(/create table (?:if not exists )?public\.(\w+)/gi)) created.add(m[1]);
  }
  assert.ok(created.size > 10, 'found the migrations');
  const missing = [...created].filter((t) => !USER_TABLES.includes(t) && !(t in NOT_PROBED)).sort();
  assert.deepEqual(missing, [], 'new tables must be probed (USER_TABLES + fixtures.rowFor) or listed in NOT_PROBED');
});

test('owner may read owner-policy tables only; everyone else is denied', () => {
  assert.equal(expectedFor('owner', 'select', 'entities'), 'allow');
  assert.equal(expectedFor('owner', 'select', 'retrieve_rate_limits'), 'deny');
  assert.equal(expectedFor('owner', 'select', 'entity_embeddings'), 'deny');
  assert.equal(expectedFor('other_user', 'select', 'entities'), 'deny');
  assert.equal(expectedFor('expired', 'delete', 'notebooks'), 'deny');
  assert.ok(OWNER_READABLE.has('session_cards'));
});

test('select: only an auth refusal is a deny; other errors are inconclusive', () => {
  const m = [A.userId];
  assert.equal(classifySelect({ kind: 'expired', table: 'entities', status: 401, body: '{}', markers: m }), 'deny');
  assert.equal(classifySelect({ kind: 'anon_only', table: 'entities', status: 403, body: '{"code":"42501"}', markers: m }), 'deny');
  assert.equal(classifySelect({ kind: 'other_user', table: 'entities', status: 404, body: '{"code":"PGRST205"}', markers: m }), 'error');
  assert.equal(classifySelect({ kind: 'other_user', table: 'entities', status: 400, body: '{}', markers: m }), 'error');
  assert.equal(classifySelect({ kind: 'other_user', table: 'entities', status: 0, body: '', markers: m }), 'error');
});

test('select: A markers visible to someone else is a leak; RLS-filtered empty is a deny', () => {
  const m = [A.userId];
  assert.equal(classifySelect({ kind: 'other_user', table: 'entities', status: 200, body: `[{"user_id":"${A.userId}"}]`, markers: m }), 'leak');
  assert.equal(classifySelect({ kind: 'other_user', table: 'entities', status: 200, body: '[]', markers: m }), 'deny');
  assert.equal(classifySelect({ kind: 'other_user', table: 'retrieve_rate_limits', status: 200, body: '[{"scope":"x"}]', markers: m }), 'leak');
});

test('select: the owner control needs its own marker, never just a 200', () => {
  const m = [A.userId];
  assert.equal(classifySelect({ kind: 'owner', table: 'session_briefs', status: 200, body: '[]', markers: m }), 'deny');
  assert.equal(classifySelect({ kind: 'owner', table: 'entities', status: 200, body: `[{"user_id":"${A.userId}"}]`, markers: m }), 'allow');
});

test('write: constraint errors mean RLS already let the row through', () => {
  assert.equal(classifyWrite({ status: 403, body: '{"code":"42501"}', changed: false }), 'deny');
  assert.equal(classifyWrite({ status: 401, body: '{}', changed: false }), 'deny');
  assert.equal(classifyWrite({ status: 200, body: '[]', changed: false }), 'deny');
  assert.equal(classifyWrite({ status: 409, body: '{"code":"23505"}', changed: false }), 'allow');
  assert.equal(classifyWrite({ status: 400, body: '{"code":"23502"}', changed: false }), 'allow');
  assert.equal(classifyWrite({ status: 201, body: '[{"id":1}]', changed: false }), 'leak');
  assert.equal(classifyWrite({ status: 403, body: '{"code":"42501"}', changed: true }), 'leak');
  assert.equal(classifyWrite({ status: 0, body: '', changed: false }), 'error');
  assert.equal(classifyWrite({ status: 500, body: '{}', changed: false }), 'error');
});

const probe = (overrides) => probeTables({
  url: 'http://127.0.0.1:55321', tables: ['entities'], kinds: ['other_user'],
  headersByKind: { other_user: { apikey: 'k', authorization: 'Bearer b' } },
  owner: A, attackerId: 'dddddddd-0000-4000-8000-000000000004', markers: [A.userId],
  rowFor: () => ({ user_id: A.userId }),
  fetchImpl: async () => new Response('[]', { status: 200 }),
  snapshot: async () => `[{"user_id":"${A.userId}"}]`,
  ...overrides,
});

test('probeTables: a table where A has no rows yields only inconclusive cells', async () => {
  const cells = await probe({ snapshot: async () => '[]' });
  assert.ok(cells.length === 4 && cells.every((c) => c.observed === 'error'));
});

test('probeTables: a write the admin snapshot sees is a leak even if the response hid it', async () => {
  let n = 0;
  const cells = await probe({
    fetchImpl: async () => new Response('{"code":"42501"}', { status: 403 }),
    snapshot: async () => `[{"user_id":"${A.userId}","v":${n++}}]`,
  });
  assert.ok(cells.filter((c) => c.operation !== 'select').every((c) => c.observed === 'leak'));
});

test('probeTables: inserts send a full valid row; updates try to hand the row to the attacker', async () => {
  const sent = [];
  await probe({ fetchImpl: async (url, init) => { sent.push({ url: String(url), method: init.method ?? 'GET', body: init.body }); return new Response('[]', { status: 200 }); } });
  const insert = sent.find((s) => s.method === 'POST');
  const update = sent.find((s) => s.method === 'PATCH');
  assert.deepEqual(JSON.parse(insert.body), { user_id: A.userId });
  assert.deepEqual(JSON.parse(update.body), { user_id: 'dddddddd-0000-4000-8000-000000000004' });
  assert.match(update.url, /user_id=eq\.aaaaaaaa/);
});

test('probeTables: an owner select that passes is flagged as a positive control', async () => {
  const cells = await probe({
    kinds: ['owner'], headersByKind: { owner: {} },
    fetchImpl: async () => new Response(`[{"user_id":"${A.userId}"}]`, { status: 200 }),
  });
  assert.equal(cells[0].control, true);
  assert.equal(cells[0].pass, true);
});
