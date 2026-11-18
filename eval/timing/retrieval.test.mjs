import { test } from 'node:test';
import assert from 'node:assert/strict';
import { paceMs, retrievalLine, queryFor } from './retrieval.mjs';
import { parseRun } from './parse.mjs';

test('a retrieval line parses as a mark in the shared format', () => {
  const text = retrievalLine({ tMs: 1234.4, durMs: 87.6, count: 4, ok: true, size: 100 });
  const { marks, rejected } = parseRun(text);
  assert.equal(rejected, 0);
  assert.deepEqual(marks[0], {
    v: 1, stage: 'retrieval_server', phase: 'span', t_ms: 1234, dur_ms: 88,
    mode: 'node', scope: 1, count: 4, ok: true, size: 100,
  });
});

test('pacing stays under the server limits (30/min per user, 20/min per notebook)', () => {
  assert.ok(paceMs(1) >= 3000); // one notebook: 20/min binds
  assert.ok(paceMs(5) >= 2000); // the user limit binds
  assert.ok(paceMs(50) >= 2000);
  assert.ok(paceMs(5) < 3000);
});

test('queries are synthetic vocabulary, varied across calls', () => {
  const qs = Array.from({ length: 10 }, (_, i) => queryFor(i));
  assert.ok(new Set(qs).size >= 5);
  for (const q of qs) assert.match(q, /^[a-z ]+$/);
});

test('entity-count buckets match the app (lib/logic/timing_marks.dart)', async () => {
  const { entityCountBucket } = await import('./buckets.mjs');
  assert.deepEqual([0, 1, 9, 10, 50, 99, 100, 500, 999, 1000, 40000].map(entityCountBucket),
    [0, 1, 1, 10, 10, 10, 100, 100, 100, 1000, 1000]);
});
