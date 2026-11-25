import { test } from 'node:test';
import assert from 'node:assert/strict';
import { summarize } from './summary.mjs';

const run = (fault, outcome, partial = 'recovered', dups = {}) => ({
  fault, outcome, pass: outcome === 'pass', partial_turn: partial,
  completed_turns_kept: { n: partial === 'lost_completed' ? 1 : 2, of: 2 },
  duplicates: { journal_entries: 0, entities: 0, ...dups },
});

test('counts outcomes, partial classes and duplicates per fault — counts, not rates', () => {
  const s = summarize([
    run('commit_lost_ack', 'pass'),
    run('commit_lost_ack', 'fail', 'duplicated', { journal_entries: 1 }),
    run('commit_lost_ack', 'not_triggered'),
    { fault: 'commit_lost_ack', seed: 4, outcome: 'error', pass: false, error: 'x' },
    run('extract_before', 'pass', 'marked'),
  ]);
  assert.deepEqual(s.faults.commit_lost_ack, {
    runs: 4, pass: 1, fail: 1, not_triggered: 1, error: 1,
    partial_turn: { recovered: 2, duplicated: 1 },
    duplicates: { journal_entries: 1, entities: 0 },
    completed_turns_kept: { n: 6, of: 6 },
  });
  assert.deepEqual(s.faults.extract_before.partial_turn, { marked: 1 });
  assert.deepEqual(s.total, { runs: 5, pass: 2, fail: 1, not_triggered: 1, error: 1 });
  assert.ok(!JSON.stringify(s).includes('%'));
});
