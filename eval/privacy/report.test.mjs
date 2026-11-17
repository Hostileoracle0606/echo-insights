import { test } from 'node:test';
import assert from 'node:assert/strict';
import { assertLocalTarget, cell, buildReport, resultsPath } from './report.mjs';

test('assertLocalTarget accepts loopback hosts', () => {
  for (const url of ['http://127.0.0.1:55321', 'http://localhost:55321', 'http://[::1]:55321']) {
    assert.ok(assertLocalTarget(url) instanceof URL);
  }
});

test('assertLocalTarget refuses a hosted project', () => {
  assert.throws(() => assertLocalTarget('https://bjoevzvsdlhlcjywpyfx.supabase.co'),
    /privacy matrix runs against local Supabase only/);
});

test('cell passes only when observed matches expected', () => {
  const base = { surface: 'table', target: 'entities', credential: 'expired', operation: 'select' };
  assert.equal(cell({ ...base, expected: 'deny', observed: 'deny' }).pass, true);
  assert.equal(cell({ ...base, expected: 'deny', observed: 'leak' }).pass, false);
});

test('buildReport counts only flagged positive controls', () => {
  const cells = [
    cell({ surface: 'table', target: 'entities', credential: 'owner', operation: 'select', expected: 'allow', observed: 'allow', control: true }),
    cell({ surface: 'table', target: 'retrieve_rate_limits', credential: 'owner', operation: 'select', expected: 'deny', observed: 'deny' }),
    cell({ surface: 'table', target: 'entities', credential: 'other_user', operation: 'select', expected: 'deny', observed: 'leak' }),
  ];
  const report = buildReport({ commit: 'abc1234', cells, startedAt: '2026-11-17T00:00:00Z' });
  assert.equal(report.version, 1);
  assert.equal(report.target, 'local');
  assert.deepEqual(report.summary, { total: 3, passed: 2, failed: 1, controls: 1, controlsPassed: 1 });
  assert.ok(report.finishedAt);
});

test('buildReport refuses cells carrying canaries, tokens or test emails', () => {
  for (const forbidden of ['CANARY-entity-0123456789abcdef', 'eyJhbGciOi', 'x@example.test']) {
    const bad = cell({ surface: 'table', target: forbidden, credential: 'owner', operation: 'select', expected: 'allow', observed: 'allow' });
    assert.throws(() => buildReport({ commit: 'abc1234', cells: [bad], startedAt: 'now' }), /forbidden content/);
  }
});

test('resultsPath is dated and pinned to the commit', () => {
  assert.equal(resultsPath(new Date('2026-11-17T12:00:00Z'), 'abc1234'),
    'eval/results/2026-11-17-abc1234/privacy.json');
});
