import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  LAMBDA_ROUTES, recordingFetch, memoryClaimStore, gatewayInvoke, classifyLambda,
} from './lambdas.mjs';

const SUPABASE = 'http://127.0.0.1:55321';

test('covers all five gateway routes on main', () => {
  assert.deepEqual(LAMBDA_ROUTES.map((r) => r.name).sort(),
    ['brief', 'close', 'extractions', 'live-sessions', 'notebook-live-sessions']);
});

test('gatewayInvoke returns 403 and never runs the handler when the authorizer denies', async () => {
  let ran = false;
  const result = await gatewayInvoke({
    authorize: async () => ({ isAuthorized: false }),
    handler: async () => { ran = true; return { statusCode: 200 }; },
    event: { headers: {} },
  });
  assert.equal(result.statusCode, 403);
  assert.equal(ran, false);
});

test('gatewayInvoke passes the authorizer context to the handler', async () => {
  const result = await gatewayInvoke({
    authorize: async () => ({ isAuthorized: true, context: { userId: 'u1' } }),
    handler: async (event) => ({ statusCode: 200, body: event.requestContext.authorizer.lambda.userId }),
    event: { headers: {} },
  });
  assert.equal(result.body, 'u1');
});

test('recordingFetch passes Supabase through and stubs and counts the provider', async () => {
  const passed = [];
  const { fetchImpl, providerCalls } = recordingFetch({
    supabaseUrl: SUPABASE,
    realFetch: async (url) => { passed.push(String(url)); return new Response('[]'); },
    providerResponder: () => new Response('{"name":"auth_tokens/fake"}'),
  });
  await fetchImpl(`${SUPABASE}/auth/v1/user`);
  const provider = await fetchImpl('https://generativelanguage.googleapis.com/v1beta/auth_tokens', { method: 'POST' });
  assert.deepEqual(passed, [`${SUPABASE}/auth/v1/user`]);
  assert.equal(providerCalls(), 1);
  assert.equal((await provider.json()).name, 'auth_tokens/fake');
});

test('memoryClaimStore: acquire, complete, replay and mismatch', async () => {
  const store = memoryClaimStore();
  const claim = { id: 'k', inputHash: 'h', ownerToken: 'o', now: 0, leaseExpiresAt: 10, expiresAt: 100 };
  assert.deepEqual(await store.acquireExtraction(claim), { status: 'acquired' });
  assert.equal((await store.acquireExtraction({ ...claim, ownerToken: 'o2', now: 1 })).status, 'pending');
  assert.deepEqual(await store.completeExtraction({ id: 'k', inputHash: 'h', ownerToken: 'o', patch: { p: 1 }, expiresAt: 100 }),
    { status: 'completed', patch: { p: 1 } });
  assert.deepEqual(await store.acquireExtraction({ ...claim, ownerToken: 'o3' }), { status: 'completed', patch: { p: 1 } });
  assert.deepEqual(await store.acquireExtraction({ ...claim, inputHash: 'other' }), { status: 'mismatch' });
});

test('classifyLambda: a deny that still spent provider quota fails as allow', () => {
  assert.equal(classifyLambda({ kind: 'expired', statusCode: 403, text: '', spent: 0, canaries: [] }), 'deny');
  assert.equal(classifyLambda({ kind: 'other_user', statusCode: 404, text: '', spent: 1, canaries: [] }), 'allow');
  assert.equal(classifyLambda({ kind: 'other_user', statusCode: 200, text: 'CANARY-entity-0011223344556677', spent: 0, canaries: ['CANARY-entity-0011223344556677'] }), 'leak');
});

test('classifyLambda: the owner is allowed once auth let it reach the provider or succeed', () => {
  assert.equal(classifyLambda({ kind: 'owner', statusCode: 503, text: '', spent: 1, canaries: [] }), 'allow');
  assert.equal(classifyLambda({ kind: 'owner', statusCode: 200, text: '', spent: 0, canaries: [] }), 'allow');
  assert.equal(classifyLambda({ kind: 'owner', statusCode: 404, text: '', spent: 0, canaries: [] }), 'deny');
});
