import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classifyKill, killReport } from './kill-audit.mjs';
import { fixtures } from './stub-lambdas.mjs';

const t1 = fixtures.turns.t1.text;
const t2 = fixtures.turns.t2.text;
const none = { journal_entries: 0, entities: 0, relations: 0, conversation_turns: 0, session_briefs: 0 };
const base = { duplicates: none, committedBeforeKill: false };

test('turn 2 resumed and committed once is recovered and passes', () => {
  const r = classifyKill({ ...base, journal: ['Earlier note.', t1, t2], turns: [t1, t2] });
  assert.deepEqual([r.partial_turn, r.outcome], ['recovered', 'pass']);
  assert.deepEqual(r.completed_turns_kept, { n: 1, of: 1 });
});

test('a turn cut mid-transcription that left only its transcript is marked', () => {
  const r = classifyKill({ ...base, journal: [t1], turns: [t1, 'Odette introduced me to Imre, who'] });
  assert.deepEqual([r.partial_turn, r.outcome], ['marked', 'pass']);
});

test('nothing of turn 2 anywhere is dropped', () => {
  assert.equal(classifyKill({ ...base, journal: [t1], turns: [t1] }).partial_turn, 'dropped');
});

test('turn 2 twice is duplicated and fails', () => {
  const r = classifyKill({ ...base, journal: [t1, t2, t2], turns: [t1, t2], duplicates: { ...none, journal_entries: 1 } });
  assert.deepEqual([r.partial_turn, r.outcome], ['duplicated', 'fail']);
});

test('losing turn 1 is lost_completed and fails', () => {
  const r = classifyKill({ ...base, journal: [t2], turns: [t1, t2] });
  assert.deepEqual([r.partial_turn, r.outcome], ['lost_completed', 'fail']);
});

test('a kill that came after turn 2 committed is not_triggered, not a pass', () => {
  const r = classifyKill({ ...base, committedBeforeKill: true, journal: [t1, t2], turns: [t1, t2] });
  assert.equal(r.outcome, 'not_triggered');
});

test('the report counts per case, out of runs', () => {
  const report = killReport([
    { case: 'extraction', outcome: 'pass', partial_turn: 'recovered' },
    { case: 'extraction', outcome: 'not_triggered', partial_turn: 'recovered' },
    { case: 'transcription', outcome: 'pass', partial_turn: 'marked' },
  ]);
  assert.deepEqual(report.extraction, { runs: 2, pass: 1, fail: 0, not_triggered: 1, error: 0, partial_turn: { recovered: 2 } });
  assert.equal(report.transcription.pass, 1);
});

test('an empty journal at relaunch with turn 2 already landed means the kill came too late', () => {
  const r = classifyKill({ ...base, found: 0, journal: [t1, t2], turns: [t1, t2] });
  assert.equal(r.outcome, 'not_triggered');
  const resumed = classifyKill({ ...base, found: 1, journal: [t1, t2], turns: [t1, t2] });
  assert.equal(resumed.outcome, 'pass');
});
