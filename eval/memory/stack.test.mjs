import { test } from 'node:test';
import assert from 'node:assert/strict';
import { localStack, withUser } from './stack.mjs';

const env = {
  SUPABASE_URL: 'http://127.0.0.1:55321', SUPABASE_ANON_KEY: 'anon',
  SUPABASE_SERVICE_ROLE_KEY: 'service', SUPABASE_JWT_SECRET: 'secret',
};

// The local auth server answers 504 when its own database connection times
// out under load (seen 2026-11-18: "failed SASL auth … i/o timeout"). A user
// delete is idempotent, so cleanup retries it instead of abandoning the run.
function scripted(statuses) {
  const seen = [];
  const fetchImpl = async (url, init) => {
    seen.push(`${init?.method ?? 'GET'} ${new URL(url).pathname}`);
    const status = statuses.shift() ?? 200;
    return new Response(status === 200 ? '{}' : '{"msg":"x"}', { status });
  };
  return { seen, fetchImpl };
}

test('deleteUser retries a timed-out delete until it succeeds', async () => {
  const { seen, fetchImpl } = scripted([504, 504, 200]);
  const waits = [];
  const stack = localStack(env, { fetchImpl, sleep: async (ms) => { waits.push(ms); } });
  await stack.deleteUser('u1');
  assert.equal(seen.length, 3);
  assert.deepEqual(waits, [1000, 2000]);
});

test('deleteUser treats 404 as already deleted', async () => {
  const { seen, fetchImpl } = scripted([504, 404]);
  const stack = localStack(env, { fetchImpl, sleep: async () => {} });
  await stack.deleteUser('u1');
  assert.equal(seen.length, 2);
});

test('deleteUser gives up after 5 attempts and says so', async () => {
  const { seen, fetchImpl } = scripted([504, 504, 504, 504, 504, 504]);
  const stack = localStack(env, { fetchImpl, sleep: async () => {} });
  await assert.rejects(stack.deleteUser('u1'), /→ 504/);
  assert.equal(seen.length, 5);
});

test('a non-transient error (403) is not retried', async () => {
  const { seen, fetchImpl } = scripted([403]);
  const stack = localStack(env, { fetchImpl, sleep: async () => {} });
  await assert.rejects(stack.deleteUser('u1'), /→ 403/);
  assert.equal(seen.length, 1);
});

test('withUser keeps the work when only cleanup fails, and reports the user left behind', async () => {
  const stack = {
    createUser: async (created) => { created.push('u1'); return { id: 'u1', token: 't' }; },
    deleteUser: async () => { throw new Error('DELETE /auth/v1/admin/users → 504'); },
  };
  const out = await withUser(stack, async (user) => `probed as ${user.id}`);
  assert.equal(out.value, 'probed as u1');
  assert.deepEqual(out.leftover, ['u1']);
});

test('withUser rethrows the work error, still deleting the user', async () => {
  const deleted = [];
  const stack = {
    createUser: async (created) => { created.push('u2'); return { id: 'u2' }; },
    deleteUser: async (id) => { deleted.push(id); },
  };
  await assert.rejects(withUser(stack, async () => { throw new Error('quota'); }), /quota/);
  assert.deepEqual(deleted, ['u2']);
});
