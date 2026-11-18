import { test } from 'node:test';
import assert from 'node:assert/strict';
import { faultyFetch } from './faults.mjs';

const counting = () => {
  const seen = [];
  const realFetch = async (url) => {
    seen.push(String(url));
    return new Response('ok', { status: 200 });
  };
  return { seen, realFetch };
};
const isCommit = (url) => String(url).endsWith('/rpc/commit_notebook');

test('before: throws on the matching request without reaching the server', async () => {
  const { seen, realFetch } = counting();
  const f = faultyFetch({ realFetch, plan: { match: isCommit, mode: 'before', after: 1 } });
  await assert.rejects(f.fetchImpl('http://x/rpc/commit_notebook'), TypeError);
  assert.deepEqual(seen, []);
  assert.equal(f.triggered(), true);
});

test('lost_ack: reaches the server exactly once, then throws', async () => {
  const { seen, realFetch } = counting();
  const f = faultyFetch({ realFetch, plan: { match: isCommit, mode: 'lost_ack', after: 1 } });
  await assert.rejects(f.fetchImpl('http://x/rpc/commit_notebook'), /network/);
  assert.deepEqual(seen, ['http://x/rpc/commit_notebook']);
  assert.equal(f.triggered(), true);
});

test('fires only on the after-th match, once; retries pass through', async () => {
  const { seen, realFetch } = counting();
  const f = faultyFetch({ realFetch, plan: { match: isCommit, mode: 'before', after: 2 } });
  assert.equal((await f.fetchImpl('http://x/rpc/commit_notebook')).status, 200);
  assert.equal(f.triggered(), false);
  await assert.rejects(f.fetchImpl('http://x/rpc/commit_notebook'));
  assert.equal((await f.fetchImpl('http://x/rpc/commit_notebook')).status, 200);
  assert.equal(seen.length, 2);
});

test('non-matching requests pass through', async () => {
  const { seen, realFetch } = counting();
  const f = faultyFetch({ realFetch, plan: { match: isCommit, mode: 'before', after: 1 } });
  assert.equal((await f.fetchImpl('http://x/rest/v1/entities')).status, 200);
  assert.deepEqual(seen, ['http://x/rest/v1/entities']);
});

test('triggered() is false when the match never occurs', async () => {
  const { realFetch } = counting();
  const f = faultyFetch({ realFetch, plan: { match: isCommit, mode: 'lost_ack', after: 1 } });
  await f.fetchImpl('http://x/rest/v1/notebooks');
  assert.equal(f.triggered(), false);
});

test('kill: never settles and never reaches the server', async () => {
  const { seen, realFetch } = counting();
  const f = faultyFetch({ realFetch, plan: { match: isCommit, mode: 'kill', after: 1 } });
  const outcome = await Promise.race([
    f.fetchImpl('http://x/rpc/commit_notebook').then(() => 'settled', () => 'settled'),
    new Promise((resolve) => setTimeout(() => resolve('pending'), 30)),
  ]);
  assert.equal(outcome, 'pending');
  assert.deepEqual(seen, []);
  assert.equal(f.triggered(), true);
});

test('rejects an unknown mode', () => {
  assert.throws(() => faultyFetch({ realFetch: fetch, plan: { match: () => true, mode: 'sideways', after: 1 } }));
});

test('kill_after: reaches the server, then never settles', async () => {
  const { seen, realFetch } = counting();
  const f = faultyFetch({ realFetch, plan: { match: isCommit, mode: 'kill_after', after: 1 } });
  const outcome = await Promise.race([
    f.fetchImpl('http://x/rpc/commit_notebook').then(() => 'settled', () => 'settled'),
    new Promise((resolve) => setTimeout(() => resolve('pending'), 30)),
  ]);
  assert.equal(outcome, 'pending');
  assert.deepEqual(seen, ['http://x/rpc/commit_notebook']);
  assert.equal(f.triggered(), true);
});
