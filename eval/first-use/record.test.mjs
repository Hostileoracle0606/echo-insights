import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateSession, sessionPath } from './record.mjs';
import { validSession } from './test-fixtures.mjs';

const here = dirname(fileURLToPath(import.meta.url));

test('accepts a complete valid session and returns it', () => {
  assert.deepEqual(validateSession(validSession()), validSession());
});

test('notes may be left out', () => {
  const { notes, ...rest } = validSession();
  assert.equal(validateSession(rest).participant, 'P1');
});

test('rejects participant ids that are not P1 to P9', () => {
  for (const participant of ['P0', 'P10', 'p1', 'Alex', 'P1 ', '']) {
    assert.throws(() => validateSession(validSession({ participant })), /participant/, participant);
  }
});

test('rejects an unknown top-level field', () => {
  assert.throws(() => validateSession(validSession({ age: 30 })), /unknown field "age"/);
});

test('rejects fields named like transcript or content, at any depth', () => {
  assert.throws(() => validateSession(validSession({ transcript: 'x' })), /transcript/);
  assert.throws(() => validateSession(validSession({ sessionContent: 'x' })), /sessionContent/);
  const confusions = [{ task: 'talk', code: 'mic_state', content: 'x' }];
  assert.throws(() => validateSession(validSession({ confusions })), /content/);
});

test('rejects unknown fields inside nested objects', () => {
  const tasks = { talk: 'yes', find: 'yes', correct: 'yes', extra: 'yes' };
  assert.throws(() => validateSession(validSession({ tasks })), /unknown field "tasks.extra"/);
  const quotes = [{ text: 'ok', approved: true, who: 'x' }];
  assert.throws(() => validateSession(validSession({ quotes })), /unknown field "quotes\[0\].who"/);
});

test('rejects any string longer than 140 characters', () => {
  const long = 'a'.repeat(141);
  assert.throws(() => validateSession(validSession({ notes: long })), /140/);
  assert.throws(() => validateSession(validSession({ quotes: [{ text: long, approved: true }] })), /140/);
  const confusions = [{ task: 'talk', code: 'other', note: long }];
  assert.throws(() => validateSession(validSession({ confusions })), /140/);
  assert.equal(validateSession(validSession({ notes: 'a'.repeat(140) })).notes.length, 140);
});

test('rejects unknown enum values', () => {
  const bad = [
    { device: 'android' },
    { firstTurnMode: 'gesture' },
    { tasks: { talk: 'maybe', find: 'yes', correct: 'yes' } },
    { listeningStateWhenAsked: 'unsure' },
    { comprehension: { listening: 'right', purpose: 'correct', keeps: 'correct' } },
    { confusions: [{ task: 'lunch', code: 'mic_state' }] },
  ];
  for (const override of bad) {
    assert.throws(() => validateSession(validSession(override)), /must be one of/, JSON.stringify(override));
  }
});

test('rejects unknown confusion codes', () => {
  const confusions = [{ task: 'talk', code: 'bored' }];
  assert.throws(() => validateSession(validSession({ confusions })), /code/);
});

test('an "other" confusion needs a note', () => {
  assert.throws(() => validateSession(validSession({ confusions: [{ task: 'find', code: 'other' }] })), /note/);
  const ok = validateSession(validSession({ confusions: [{ task: 'find', code: 'other', note: 'looked for search' }] }));
  assert.equal(ok.confusions[0].note, 'looked for search');
});

test('rejects missing required fields', () => {
  for (const field of ['participant', 'date', 'device', 'consent', 'tasks', 'comprehension', 'confusions', 'quotes']) {
    const session = validSession();
    delete session[field];
    assert.throws(() => validateSession(session), new RegExp(field), field);
  }
  const tasks = { talk: 'yes', find: 'yes' };
  assert.throws(() => validateSession(validSession({ tasks })), /tasks.correct/);
});

test('requires consent to be exactly true', () => {
  assert.throws(() => validateSession(validSession({ consent: false })), /consent/);
  assert.throws(() => validateSession(validSession({ consent: 'yes' })), /consent/);
});

test('rejects a date that is not YYYY-MM-DD', () => {
  for (const date of ['20/11/2026', '2026-13-01', '2026-11-20T10:00:00Z']) {
    assert.throws(() => validateSession(validSession({ date })), /date/, date);
  }
});

test('time to first turn is whole seconds within the 8-minute task, or null with no mode', () => {
  for (const secondsToFirstTurn of [-1, 1.5, 481, '42']) {
    assert.throws(() => validateSession(validSession({ secondsToFirstTurn })), /secondsToFirstTurn/, String(secondsToFirstTurn));
  }
  assert.equal(validateSession(validSession({ secondsToFirstTurn: null, firstTurnMode: null })).secondsToFirstTurn, null);
  assert.throws(() => validateSession(validSession({ secondsToFirstTurn: null })), /firstTurnMode/);
  assert.throws(() => validateSession(validSession({ firstTurnMode: null })), /firstTurnMode/);
});

test('quotes need a boolean approved flag', () => {
  assert.throws(() => validateSession(validSession({ quotes: [{ text: 'ok' }] })), /approved/);
  assert.throws(() => validateSession(validSession({ quotes: [{ text: 'ok', approved: 'yes' }] })), /approved/);
});

test('rejects a non-object or an array', () => {
  assert.throws(() => validateSession(null), /object/);
  assert.throws(() => validateSession([]), /object/);
});

test('sessionPath puts one file per participant under the dated commit folder', () => {
  assert.equal(
    sessionPath(new Date('2026-11-20T15:00:00Z'), 'abc1234', 'P3'),
    'eval/results/2026-11-20-abc1234/first-use/P3.json',
  );
});

test('the observation sheet JSON example is a valid session', () => {
  const sheet = readFileSync(resolve(here, 'observation-sheet.md'), 'utf8');
  const example = sheet.match(/```json\n([\s\S]*?)```/)[1];
  assert.equal(validateSession(JSON.parse(example)).participant, 'P1');
});

test('every field row on the observation sheet is a field of the schema, and the reverse', () => {
  const sheet = readFileSync(resolve(here, 'observation-sheet.md'), 'utf8');
  const sheetFields = [...sheet.matchAll(/^\| `([a-zA-Z.]+)` \|/gm)].map((m) => m[1]).sort();
  const session = validSession();
  const schemaFields = Object.entries(session)
    .flatMap(([key, value]) => (key === 'tasks' || key === 'comprehension'
      ? Object.keys(value).map((sub) => `${key}.${sub}`)
      : [key]))
    .sort();
  assert.deepEqual(sheetFields, schemaFields);
});

test('rejects a quote the person did not approve, so its words never reach the repo', () => {
  assert.throws(() => validateSession(validSession({ quotes: [{ text: 'They said no.', approved: false }] })), /approved/);
});

test('a skipped task or question is coded as skipped, not as a failure', () => {
  const s = validateSession(validSession({
    tasks: { talk: 'yes', find: 'skipped', correct: 'skipped' },
    comprehension: { listening: 'correct', purpose: 'skipped', keeps: 'wrong' },
  }));
  assert.equal(s.tasks.find, 'skipped');
  assert.equal(s.comprehension.purpose, 'skipped');
});
