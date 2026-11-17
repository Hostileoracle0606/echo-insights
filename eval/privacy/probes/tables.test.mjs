import { test } from 'node:test';
import assert from 'node:assert/strict';
import { USER_TABLES, OWNER_READABLE, expectedFor, classifySelect, probeTables } from './tables.mjs';

const A = { userId: 'aaaaaaaa-0000-4000-8000-000000000001', notebookId: 'bbbbbbbb-0000-4000-8000-000000000002' };

test('covers every user table on main', () => {
  assert.equal(USER_TABLES.length, 18);
  for (const t of ['session_briefs', 'suppression_keys', 'forget_erase_jobs']) assert.ok(USER_TABLES.includes(t));
});

test('owner may read owner-policy tables only; everyone else is denied', () => {
  assert.equal(expectedFor('owner', 'select', 'entities'), 'allow');
  assert.equal(expectedFor('owner', 'select', 'retrieve_rate_limits'), 'deny');
  assert.equal(expectedFor('owner', 'select', 'entity_embeddings'), 'deny');
  assert.equal(expectedFor('other_user', 'select', 'entities'), 'deny');
  assert.equal(expectedFor('expired', 'delete', 'notebooks'), 'deny');
  assert.ok(OWNER_READABLE.has('session_cards'));
});

test('select is a leak when A markers show up for someone else', () => {
  const body = JSON.stringify([{ user_id: A.userId }]);
  assert.equal(classifySelect({ kind: 'other_user', table: 'entities', status: 200, body, markers: [A.userId], seeded: true }), 'leak');
  assert.equal(classifySelect({ kind: 'other_user', table: 'entities', status: 200, body: '[]', markers: [A.userId], seeded: true }), 'deny');
  assert.equal(classifySelect({ kind: 'missing', table: 'entities', status: 401, body: '{}', markers: [A.userId], seeded: true }), 'deny');
});

test('any visible row in a table nobody may read is a leak', () => {
  assert.equal(classifySelect({ kind: 'other_user', table: 'retrieve_rate_limits', status: 200, body: '[{"scope":"x"}]', markers: [], seeded: false }), 'leak');
});

test('owner control requires their own seeded row, not just a 200', () => {
  assert.equal(classifySelect({ kind: 'owner', table: 'entities', status: 200, body: '[]', markers: [A.userId], seeded: true }), 'deny');
  assert.equal(classifySelect({ kind: 'owner', table: 'entities', status: 200, body: `[{"user_id":"${A.userId}"}]`, markers: [A.userId], seeded: true }), 'allow');
});

test('probeTables marks a write that changed A rows as a leak', async () => {
  const fetchImpl = async (url, init = {}) => {
    const method = init.method ?? 'GET';
    if (method === 'PATCH') return new Response(JSON.stringify([{ user_id: A.userId }]), { status: 200 });
    return new Response('[]', { status: 200 });
  };
  const cells = await probeTables({
    url: 'http://127.0.0.1:55321', tables: ['entities'], kinds: ['other_user'],
    headersByKind: { other_user: { apikey: 'k', authorization: 'Bearer b' } },
    owner: A, markers: [A.userId], seededTables: new Set(['entities']), fetchImpl,
    snapshot: async () => 'same',
  });
  const update = cells.find((c) => c.operation === 'update');
  assert.equal(update.observed, 'leak');
  assert.equal(update.pass, false);
  assert.equal(cells.find((c) => c.operation === 'select').pass, true);
});

test('probeTables marks a write as leak when the admin snapshot changed even if the response hid it', async () => {
  let n = 0;
  const cells = await probeTables({
    url: 'http://127.0.0.1:55321', tables: ['entities'], kinds: ['expired'],
    headersByKind: { expired: { apikey: 'k', authorization: 'Bearer x' } },
    owner: A, markers: [A.userId], seededTables: new Set(['entities']),
    fetchImpl: async () => new Response('{}', { status: 401 }),
    snapshot: async () => `v${n++}`,
  });
  assert.ok(cells.filter((c) => c.operation !== 'select').every((c) => c.observed === 'leak'));
});
