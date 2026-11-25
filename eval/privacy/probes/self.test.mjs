import { test } from 'node:test';
import assert from 'node:assert/strict';
import { probeSelf } from './self.mjs';

const ids = { owner: 'aaaaaaaa-0000-4000-8000-000000000001', deleted_user: 'cccccccc-0000-4000-8000-000000000003' };
const headersByKind = { owner: { authorization: 'Bearer A' }, deleted_user: { authorization: 'Bearer C' } };
const run = (respond) => probeSelf({ url: 'http://127.0.0.1:55321', headersByKind, ids, fetchImpl: async (url, init) => respond(String(url), init) });

test('owner is the control on both self-scope probes', async () => {
  const cells = await run((url) => new Response(url.includes('/auth/v1/user') ? '{"id":"x"}' : '[{"id":"n"}]', { status: url.includes('/auth/') ? 200 : 201 }));
  const owner = cells.filter((c) => c.credential === 'owner');
  assert.deepEqual(owner.map((c) => [c.operation, c.control, c.pass]), [['auth_user', true, true], ['self_notebook_insert', true, true]]);
});

test('a deleted user refused by auth and by RLS passes', async () => {
  const cells = await run((url, init) => (init.headers.authorization === 'Bearer A'
    ? new Response('[{}]', { status: url.includes('/auth/') ? 200 : 201 })
    : new Response('{"code":"42501"}', { status: 403 })));
  assert.ok(cells.filter((c) => c.credential === 'deleted_user').every((c) => c.observed === 'deny' && c.pass));
});

test('a deleted user whose token RLS accepts, stopped only by a foreign key, fails as allow', async () => {
  const cells = await run((url, init) => {
    if (init.headers.authorization === 'Bearer A') return new Response('[{}]', { status: url.includes('/auth/') ? 200 : 201 });
    return url.includes('/auth/') ? new Response('{}', { status: 403 }) : new Response('{"code":"23503"}', { status: 409 });
  });
  const insert = cells.find((c) => c.credential === 'deleted_user' && c.operation === 'self_notebook_insert');
  assert.equal(insert.observed, 'allow');
  assert.equal(insert.pass, false);
});

test('the inserted row belongs to the caller, never to A', async () => {
  const bodies = [];
  await run((url, init) => { if (init.body) bodies.push(JSON.parse(init.body)); return new Response('[]', { status: 201 }); });
  assert.deepEqual(bodies.map((b) => b.user_id), [ids.owner, ids.deleted_user]);
});
