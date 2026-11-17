import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FUNCTION_TARGETS, classifyFunction, probeFunctions } from './functions.mjs';
import { newCanary } from '../canary.mjs';

const KINDS = ['owner', 'missing', 'anon_only', 'expired', 'forged', 'malformed', 'other_user', 'deleted_user'];
const headersByKind = Object.fromEntries(KINDS.map((k) => [k, { apikey: 'k', authorization: `Bearer ${k}` }]));

test('targets every edge function on main', () => {
  assert.deepEqual(FUNCTION_TARGETS.map((t) => t.name).sort(),
    ['embed-entities', 'extract-graph', 'retrieve-memory', 'speak-agent']);
});

test('classifyFunction: 4xx denies, 2xx allows, canary leaks, 5xx errors', () => {
  const c = newCanary('query');
  assert.equal(classifyFunction({ status: 401, text: '{}', canaries: [c] }), 'deny');
  assert.equal(classifyFunction({ status: 404, text: '{"error":"notebook not found"}', canaries: [c] }), 'deny');
  assert.equal(classifyFunction({ status: 400, text: `{"error":"${c}"}`, canaries: [c] }), 'leak');
  assert.equal(classifyFunction({ status: 200, text: '{}', canaries: [c] }), 'allow');
  assert.equal(classifyFunction({ status: 502, text: '', canaries: [c] }), 'error');
});

test('an error body echoing the request canary is a failing leak cell', async () => {
  const cells = await probeFunctions({
    url: 'http://127.0.0.1:55321', kinds: ['other_user'], headersByKind,
    notebookId: 'nb', canaries: [], internalSecret: 's', targets: ['retrieve-memory'],
    fetchImpl: async (_url, init) => new Response(init.body, { status: 400 }),
  });
  assert.ok(cells.length >= 2);
  assert.ok(cells.every((c) => c.observed === 'leak' && !c.pass));
});

test('401 for a bad credential is a passing deny cell', async () => {
  const cells = await probeFunctions({
    url: 'http://127.0.0.1:55321', kinds: ['expired'], headersByKind,
    notebookId: 'nb', canaries: [], internalSecret: 's', targets: ['retrieve-memory'],
    fetchImpl: async () => new Response('{"msg":"Invalid JWT"}', { status: 401 }),
  });
  assert.ok(cells.every((c) => c.expected === 'deny' && c.pass));
});

test('provider-spending functions are never called with owner or other_user', async () => {
  const seen = [];
  await probeFunctions({
    url: 'http://127.0.0.1:55321', kinds: KINDS, headersByKind, notebookId: 'nb',
    canaries: [], internalSecret: 's', targets: ['speak-agent', 'extract-graph'],
    fetchImpl: async (_url, init) => { seen.push(init.headers.authorization); return new Response('{}', { status: 401 }); },
  });
  assert.ok(!seen.includes('Bearer owner') && !seen.includes('Bearer other_user'));
  assert.ok(seen.includes('Bearer deleted_user'));
});

test('embed-entities is denied without the internal secret even for the owner, and with a wrong one', async () => {
  const sent = [];
  const cells = await probeFunctions({
    url: 'http://127.0.0.1:55321', kinds: ['owner'], headersByKind, notebookId: 'nb',
    canaries: [], internalSecret: 'right', targets: ['embed-entities'],
    fetchImpl: async (_url, init) => { sent.push(init.headers['x-internal-secret']); return new Response('forbidden', { status: 403 }); },
  });
  assert.deepEqual(cells.map((c) => c.credential).sort(), ['owner', 'wrong_secret']);
  assert.ok(cells.every((c) => c.expected === 'deny' && c.pass));
  assert.ok(!sent.includes('right'));
});
