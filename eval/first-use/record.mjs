// First-use study recorder: `node eval/first-use/record.mjs <sheet.json>`.
// Validates one session's coded observations and writes them to
// eval/results/<date>-<sha>/first-use/P<n>.json. The schema is closed: only
// coded values and short notes, so participant content has nowhere to go.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const MAX_TEXT = 140;
export const TASKS = Object.freeze(['talk', 'find', 'correct']);
export const COMPLETION = Object.freeze(['yes', 'with_help', 'no', 'skipped']);
export const QUESTIONS = Object.freeze(['listening', 'purpose', 'keeps']);
export const SCORES = Object.freeze(['correct', 'partial', 'wrong', 'skipped']);
export const CONFUSION_CODES = Object.freeze(['mic_state', 'what_to_say', 'where_memory_is', 'correction_path', 'permissions', 'other']);
export const CONFUSION_TASKS = Object.freeze(['setup', 'talk', 'checks', 'find', 'correct']);
const DEVICES = ['simulator', 'testflight'];
const TURN_MODES = ['voice', 'typed'];
const LISTENING_STATES = ['listening', 'not_listening'];
const TOP_LEVEL = ['participant', 'date', 'device', 'consent', 'secondsToFirstTurn', 'firstTurnMode', 'tasks',
  'listeningStateWhenAsked', 'comprehension', 'confusions', 'quotes', 'notes'];
const MAX_SECONDS = 8 * 60; // Task 1's time limit
const CONTENT_LIKE = /transcript|content/i;

const fail = (message) => { throw new Error(`invalid session: ${message}`); };

function checkKeys(obj, allowed, path) {
  for (const key of Object.keys(obj)) {
    const where = path ? `${path}.${key}` : key;
    if (CONTENT_LIKE.test(key)) fail(`field "${where}" looks like participant content and is never recorded`);
    if (!allowed.includes(key)) fail(`unknown field "${where}"`);
  }
}

function checkStrings(value, path) {
  if (typeof value === 'string' && value.length > MAX_TEXT) {
    fail(`${path} is ${value.length} characters; free text is limited to ${MAX_TEXT}`);
  }
  if (value && typeof value === 'object') {
    for (const [key, inner] of Object.entries(value)) checkStrings(inner, Array.isArray(value) ? `${path}[${key}]` : `${path}.${key}`);
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function oneOf(value, allowed, path) {
  if (!allowed.includes(value)) fail(`${path} must be one of ${allowed.join(', ')}`);
}

function requireObject(value, path) {
  if (!isPlainObject(value)) fail(`${path} must be an object`);
}

function enumMap(value, keys, allowed, path) {
  requireObject(value, path);
  checkKeys(value, keys, path);
  for (const key of keys) {
    if (!(key in value)) fail(`missing ${path}.${key}`);
    oneOf(value[key], allowed, `${path}.${key}`);
  }
}

function validDate(text) {
  if (typeof text !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(text)) return false;
  const parsed = new Date(`${text}T00:00:00Z`);
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === text;
}

export function validateSession(obj) {
  if (!isPlainObject(obj)) fail('a session must be a JSON object');
  checkKeys(obj, TOP_LEVEL, '');
  for (const key of TOP_LEVEL.filter((k) => k !== 'notes')) {
    if (!(key in obj)) fail(`missing ${key}`);
  }
  checkStrings(obj, 'session');

  if (typeof obj.participant !== 'string' || !/^P[1-9]$/.test(obj.participant)) {
    fail('participant must be a code P1 to P9, never a name');
  }
  if (!validDate(obj.date)) fail('date must be a real date written YYYY-MM-DD');
  oneOf(obj.device, DEVICES, 'device');
  if (obj.consent !== true) fail('consent must be true; without consent nothing is recorded');

  const seconds = obj.secondsToFirstTurn;
  if (seconds !== null && !(Number.isInteger(seconds) && seconds >= 0 && seconds <= MAX_SECONDS)) {
    fail(`secondsToFirstTurn must be whole seconds from 0 to ${MAX_SECONDS}, or null`);
  }
  if ((seconds === null) !== (obj.firstTurnMode === null)) {
    fail('firstTurnMode must be null exactly when secondsToFirstTurn is null');
  }
  if (obj.firstTurnMode !== null) oneOf(obj.firstTurnMode, TURN_MODES, 'firstTurnMode');

  enumMap(obj.tasks, TASKS, COMPLETION, 'tasks');
  oneOf(obj.listeningStateWhenAsked, LISTENING_STATES, 'listeningStateWhenAsked');
  enumMap(obj.comprehension, QUESTIONS, SCORES, 'comprehension');

  if (!Array.isArray(obj.confusions)) fail('confusions must be a list');
  obj.confusions.forEach((c, i) => {
    const path = `confusions[${i}]`;
    requireObject(c, path);
    checkKeys(c, ['task', 'code', 'note'], path);
    oneOf(c.task, CONFUSION_TASKS, `${path}.task`);
    oneOf(c.code, CONFUSION_CODES, `${path}.code`);
    if ('note' in c && typeof c.note !== 'string') fail(`${path}.note must be text`);
    if (c.code === 'other' && !c.note?.trim()) fail(`${path} is "other" and needs a note saying what it was`);
  });

  if (!Array.isArray(obj.quotes)) fail('quotes must be a list');
  obj.quotes.forEach((q, i) => {
    const path = `quotes[${i}]`;
    requireObject(q, path);
    checkKeys(q, ['text', 'approved'], path);
    if (typeof q.text !== 'string' || !q.text.trim()) fail(`${path}.text must be text`);
    // Words the person did not approve are never recorded, so never reach the repository.
    if (q.approved !== true) fail(`${path}.approved must be true; leave out quotes the person did not approve`);
  });

  if ('notes' in obj && typeof obj.notes !== 'string') fail('notes must be text');
  return obj;
}

export function sessionPath(date, sha, participant) {
  return `eval/results/${date.toISOString().slice(0, 10)}-${sha}/first-use/${participant}.json`;
}

// Every recorded session in the repo, so one participant code is used once.
export function recordedSessions(root) {
  const results = resolve(root, 'eval/results');
  if (!existsSync(results)) return [];
  return readdirSync(results).flatMap((run) => {
    const dir = resolve(results, run, 'first-use');
    if (!existsSync(dir)) return [];
    return readdirSync(dir).filter((f) => /^P[1-9]\.json$/.test(f)).map((f) => `eval/results/${run}/first-use/${f}`);
  });
}

function main() {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const input = process.argv[2];
  if (!input) {
    console.error('usage: node eval/first-use/record.mjs <sheet.json>');
    process.exit(2);
  }
  let session;
  try {
    session = validateSession(JSON.parse(readFileSync(input, 'utf8')));
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
  const taken = recordedSessions(root).filter((p) => p.endsWith(`/${session.participant}.json`));
  if (taken.length) {
    console.error(`${session.participant} is already recorded at ${taken[0]}; use the next free code`);
    process.exit(1);
  }
  const sha = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root }).toString().trim();
  const out = sessionPath(new Date(), sha, session.participant);
  mkdirSync(dirname(resolve(root, out)), { recursive: true });
  writeFileSync(resolve(root, out), `${JSON.stringify(session, null, 2)}\n`);
  console.log(`recorded ${session.participant} → ${out}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
