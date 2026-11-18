import { test } from 'node:test';
import assert from 'node:assert/strict';
import { summarize, summaryPath } from './summarize.mjs';
import { validSession } from './test-fixtures.mjs';

// Four hand-built sessions; expected counts are worked out by hand below.
const sessions = [
  validSession({
    participant: 'P1', secondsToFirstTurn: 30, firstTurnMode: 'voice',
    tasks: { talk: 'yes', find: 'yes', correct: 'yes' },
    comprehension: { listening: 'correct', purpose: 'correct', keeps: 'partial' },
    confusions: [{ task: 'talk', code: 'mic_state' }, { task: 'talk', code: 'mic_state' }],
    quotes: [{ text: 'Approved one.', approved: true }],
  }),
  validSession({
    participant: 'P2', secondsToFirstTurn: 90, firstTurnMode: 'typed',
    tasks: { talk: 'yes', find: 'with_help', correct: 'no' },
    comprehension: { listening: 'wrong', purpose: 'partial', keeps: 'wrong' },
    confusions: [{ task: 'find', code: 'where_memory_is' }, { task: 'talk', code: 'mic_state' }],
    quotes: [{ text: 'Said no to this one.', approved: false }],
  }),
  validSession({
    participant: 'P3', secondsToFirstTurn: 60, firstTurnMode: 'voice',
    tasks: { talk: 'with_help', find: 'no', correct: 'no' },
    comprehension: { listening: 'partial', purpose: 'correct', keeps: 'wrong' },
    confusions: [{ task: 'correct', code: 'other', note: 'looked for undo' }],
    quotes: [],
  }),
  validSession({
    participant: 'P4', secondsToFirstTurn: null, firstTurnMode: null,
    tasks: { talk: 'no', find: 'no', correct: 'no' },
    comprehension: { listening: 'correct', purpose: 'wrong', keeps: 'correct' },
    confusions: [],
    quotes: [{ text: 'Approved two.', approved: true }],
  }),
];

test('counts participants', () => {
  assert.equal(summarize(sessions).participants, 4);
});

test('time to first turn: how many reached it, median and range of those who did', () => {
  assert.deepEqual(summarize(sessions).timeToFirstTurn, {
    reached: 3, of: 4, medianSeconds: 60, minSeconds: 30, maxSeconds: 90,
    byMode: { voice: 2, typed: 1 },
  });
});

test('median of an even number of times is the mean of the middle two', () => {
  const two = [sessions[0], sessions[2]];
  assert.equal(summarize(two).timeToFirstTurn.medianSeconds, 45);
});

test('nobody reaching a first turn gives null median and range', () => {
  const t = summarize([sessions[3]]).timeToFirstTurn;
  assert.deepEqual(t, { reached: 0, of: 1, medianSeconds: null, minSeconds: null, maxSeconds: null, byMode: { voice: 0, typed: 0 } });
});

test('completion counts per task', () => {
  assert.deepEqual(summarize(sessions).tasks, {
    talk: { yes: 2, with_help: 1, no: 1, skipped: 0, of: 4 },
    find: { yes: 1, with_help: 1, no: 2, skipped: 0, of: 4 },
    correct: { yes: 1, with_help: 0, no: 3, skipped: 0, of: 4 },
  });
});

test('confusions per code: total moments and how many people had it', () => {
  assert.deepEqual(summarize(sessions).confusions, {
    mic_state: { moments: 3, participants: 2, of: 4 },
    what_to_say: { moments: 0, participants: 0, of: 4 },
    where_memory_is: { moments: 1, participants: 1, of: 4 },
    correction_path: { moments: 0, participants: 0, of: 4 },
    permissions: { moments: 0, participants: 0, of: 4 },
    other: { moments: 1, participants: 1, of: 4 },
  });
});

test('comprehension counts per question', () => {
  assert.deepEqual(summarize(sessions).comprehension, {
    listening: { correct: 2, partial: 1, wrong: 1, skipped: 0, of: 4 },
    purpose: { correct: 2, partial: 1, wrong: 1, skipped: 0, of: 4 },
    keeps: { correct: 1, partial: 1, wrong: 2, skipped: 0, of: 4 },
  });
});

test('keeps approved quotes only and drops the unapproved one', () => {
  const { quotes } = summarize(sessions);
  assert.deepEqual(quotes, [
    { participant: 'P1', text: 'Approved one.' },
    { participant: 'P4', text: 'Approved two.' },
  ]);
  assert.ok(!JSON.stringify(summarize(sessions)).includes('Said no to this one.'));
});

test('a quote with no approved flag is dropped too', () => {
  const s = structuredClone(sessions[0]);
  s.quotes = [{ text: 'No flag.' }];
  assert.deepEqual(summarize([s]).quotes, []);
});

test('skips are counted on their own, not as failures', () => {
  const s = validSession({ participant: 'P5', tasks: { talk: 'yes', find: 'skipped', correct: 'no' },
    comprehension: { listening: 'correct', purpose: 'skipped', keeps: 'wrong' } });
  const summary = summarize([sessions[0], s]);
  assert.deepEqual(summary.tasks.find, { yes: 1, with_help: 0, no: 0, skipped: 1, of: 2 });
  assert.deepEqual(summary.comprehension.purpose, { correct: 1, partial: 0, wrong: 0, skipped: 1, of: 2 });
});

test('reports counts, never percentages or fractions', () => {
  const summary = summarize(sessions);
  const text = JSON.stringify(summary);
  assert.ok(!text.includes('%'));
  assert.ok(!/percent|rate|ratio|share/i.test(Object.keys(flatten(summary)).join(' ')));
  for (const [key, value] of Object.entries(flatten(summary))) {
    if (typeof value === 'number' && !key.endsWith('Seconds')) assert.ok(Number.isInteger(value), `${key}=${value}`);
  }
});

test('free-text notes are not carried into the summary', () => {
  const s = structuredClone(sessions[0]);
  s.notes = 'private behaviour note';
  const text = JSON.stringify(summarize([s, sessions[2]]));
  assert.ok(!text.includes('private behaviour note'));
  assert.ok(!text.includes('looked for undo'));
});

test('re-validates every session and refuses duplicates', () => {
  assert.throws(() => summarize([sessions[0], sessions[0]]), /P1.*more than once/);
  assert.throws(() => summarize([{ ...sessions[0], transcript: 'x' }]), /transcript/);
});

test('refuses an empty study', () => {
  assert.throws(() => summarize([]), /no sessions/);
});

test('summaryPath sits beside the run folders', () => {
  assert.equal(summaryPath(new Date('2026-12-01T09:00:00Z'), 'def5678'), 'eval/results/2026-12-01-def5678/first-use.json');
});

function flatten(value, prefix = '', out = {}) {
  if (value && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) flatten(v, prefix ? `${prefix}.${k}` : k, out);
  } else {
    out[prefix] = value;
  }
  return out;
}
