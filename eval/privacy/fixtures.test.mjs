import { test } from 'node:test';
import assert from 'node:assert/strict';
import { rowFor, SEED_ORDER } from './fixtures.mjs';
import { USER_TABLES } from './probes/tables.mjs';

const ctx = {
  userId: 'aaaaaaaa-0000-4000-8000-000000000001', notebookId: 'bbbbbbbb-0000-4000-8000-000000000002',
  sessionId: 'cccccccc-0000-4000-8000-000000000003', marker: 'CANARY-seed-0011223344556677', unique: 'u1',
};

test('every user table has a seed row and a seed position', () => {
  assert.deepEqual([...SEED_ORDER].sort(), [...USER_TABLES].filter((t) => t !== 'profiles').sort());
  for (const table of SEED_ORDER) assert.equal(typeof rowFor(table, ctx), 'object', table);
});

test('rows that carry content carry the marker so leaks are visible', () => {
  for (const table of SEED_ORDER) {
    const row = JSON.stringify(rowFor(table, ctx));
    assert.ok(row.includes(ctx.marker) || row.includes(ctx.userId), `${table} has no marker`);
  }
  assert.ok(JSON.stringify(rowFor('retrieve_rate_limits', ctx)).includes(ctx.marker));
  assert.ok(JSON.stringify(rowFor('conversation_runtime_inbox', ctx)).includes(ctx.marker));
});

test('unique ids change with ctx.unique so inserts never collide with the seed', () => {
  assert.notEqual(rowFor('entities', ctx).id, rowFor('entities', { ...ctx, unique: 'u2' }).id);
  assert.notEqual(rowFor('conversation_turns', ctx).turn_id, rowFor('conversation_turns', { ...ctx, unique: 'u2' }).turn_id);
});

test('embedding is a 384-dimension vector literal', () => {
  assert.equal(JSON.parse(rowFor('entity_embeddings', ctx).embedding).length, 384);
});
