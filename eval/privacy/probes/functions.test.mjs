import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FUNCTION_TARGETS, classifyFunction, probeFunctions } from './functions.mjs';
import { newCanary } from '../canary.mjs';

const KINDS = ['owner', 'missing', 'anon_only', 'expired', 'forged', 'malformed', 'other_user', 'deleted_user'];
const headersByKind = Object.fromEntries(KINDS.map((k) => [k, { apikey: 'k', authorization: `Bearer ${k}` }]));
const base = { url: 'http://127.0.0.1:55321', headersByKind, notebookId: 'nb', canaries: [], internalSecret: 's', ownerMarkers: ['pm-entity-a'] };

test('targets every edge function on main', () => {
  assert.deepEqual(FUNCTION_TARGETS.map((t) => t.name).sort(),
    ['embed-entities', 'extract-graph', 'retrieve-memory', 'speak-agent']);
});

test('classifyFunction: only auth refusals and post-auth notebook refusals deny', () => {
  const c = newCanary('query');
  assert.equal(classifyFunction({ status: 401, text: '{}', canaries: [c] }), 'deny');
  assert.equal(classifyFunction({ status: 403, text: 'forbidden', canaries: [c] }), 'deny');
  assert.equal(classifyFunction({ status: 404, text: '{"error":"notebook not found"}', canaries: [c] }), 'deny');
  assert.equal(classifyFunction({ status: 404, text: 'Function not found', canaries: [c] }), 'error');
  assert.equal(classifyFunction({ status: 402, text: '{"error":"payment"}', canaries: [c] }), 'error');
  assert.equal(classifyFunction({ status: 501, text: '{"error":"ELEVENLABS_API_KEY is not configured"}', canaries: [c] }), 'allow');
  assert.equal(classifyFunction({ status: 200, text: '{}', canaries: [c] }), 'allow');
  assert.equal(classifyFunction({ status: 400, text: `{"error":"${c}"}`, canaries: [c] }), 'leak');
  assert.equal(classifyFunction({ status: 0, text: '', canaries: [c] }), 'error');
});

test('an error body echoing the request canary is a failing leak cell', async () => {
  const cells = await probeFunctions({
    ...base, kinds: ['other_user'], targets: ['retrieve-memory'],
    fetchImpl: async (_url, init) => new Response(init.body, { status: 400 }),
  });
  assert.ok(cells.some((c) => c.observed === 'leak' && !c.pass));
});

test('when the owner control passes, a 401 for a bad credential is a passing deny', async () => {
  const cells = await probeFunctions({
    ...base, kinds: ['owner', 'expired'], targets: ['retrieve-memory'],
    fetchImpl: async (_url, init) => (init.headers.authorization === 'Bearer owner'
      ? new Response('{"entityIds":["pm-entity-a"]}', { status: 200 })
      : new Response('{"msg":"Invalid JWT"}', { status: 401 })),
  });
  const control = cells.find((c) => c.control);
  assert.equal(control.pass, true);
  assert.ok(cells.filter((c) => c.credential === 'expired').every((c) => c.observed === 'deny' && c.pass));
});

test('when the owner control fails, that function\'s denies are inconclusive', async () => {
  const cells = await probeFunctions({
    ...base, kinds: ['owner', 'expired'], targets: ['retrieve-memory'],
    fetchImpl: async () => new Response('{"msg":"Invalid JWT"}', { status: 401 }),
  });
  assert.ok(cells.filter((c) => c.credential === 'expired').every((c) => c.observed === 'error'));
});

test('retrieve-memory owner control needs A\'s entity in the answer, not just a 200', async () => {
  const cells = await probeFunctions({
    ...base, kinds: ['owner'], targets: ['retrieve-memory'],
    fetchImpl: async () => new Response('{"entityIds":[]}', { status: 200 }),
  });
  const control = cells.find((c) => c.control);
  assert.equal(control.observed, 'error');
});

test('legacy extract-graph owner control proves auth with a notebook that does not exist', async () => {
  const bodies = [];
  const cells = await probeFunctions({
    ...base, kinds: ['owner'], targets: ['extract-graph'],
    fetchImpl: async (_url, init) => { bodies.push(JSON.parse(init.body)); return new Response('{"error":"notebook not found"}', { status: 404 }); },
  });
  assert.notEqual(bodies[0].notebookId, 'nb');
  assert.equal(cells.find((c) => c.control).pass, true);
});

test('speak-agent: a second real user may use it, a deleted one may not', async () => {
  const cells = await probeFunctions({
    ...base, kinds: ['owner', 'other_user', 'deleted_user'], targets: ['speak-agent'],
    fetchImpl: async () => new Response('{}', { status: 401 }),
  });
  const expected = Object.fromEntries(cells.map((c) => [c.credential, c.expected]));
  assert.deepEqual(expected, { owner: 'allow', other_user: 'allow', deleted_user: 'deny' });
});

test('embed-entities: denied without the secret, allowed with it as its control', async () => {
  const cells = await probeFunctions({
    ...base, kinds: ['owner'], internalSecret: 'right', targets: ['embed-entities'],
    fetchImpl: async (_url, init) => new Response(init.headers['x-internal-secret'] === 'right' ? '{"ok":true}' : 'forbidden',
      { status: init.headers['x-internal-secret'] === 'right' ? 200 : 403 }),
  });
  const byCred = Object.fromEntries(cells.map((c) => [c.credential, c]));
  assert.equal(byCred.internal_secret.control, true);
  assert.equal(byCred.internal_secret.pass, true);
  assert.equal(byCred.owner.observed, 'deny');
  assert.equal(byCred.wrong_secret.observed, 'deny');
});
