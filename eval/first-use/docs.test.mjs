import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const read = (f) => readFileSync(resolve(here, f), 'utf8');
// protocol.md's ground rules: never said before the three questions.
const BANNED = /\b(listening|listen|microphone|mic|recording|memory|remember|keep|keeps|kept|save|saved|notes|graph)\b/i;

test('the consent read aloud uses none of the words banned before the questions', () => {
  const spoken = read('consent.md').split('\n---\n')[1];
  assert.ok(spoken.length > 500, 'found the read-aloud block');
  const hits = spoken.split('\n').filter((line) => BANNED.test(line));
  assert.deepEqual(hits, []);
});

test('nothing the facilitator says before the questions uses a banned word', () => {
  const protocol = read('protocol.md');
  const before = protocol.slice(protocol.indexOf('## Help ladder'), protocol.indexOf('## 3. The three questions'));
  const spoken = [...before.matchAll(/\*\*"([^"]+)"\*\*/g)].map((m) => m[1]);
  assert.ok(spoken.length >= 4, 'found the spoken lines');
  assert.deepEqual(spoken.filter((line) => BANNED.test(line)), []);
});

test('the consent is honest that speech goes to Google and that coded records are published', () => {
  const consent = read('consent.md');
  assert.match(consent, /Google/);
  assert.match(consent, /Gemini/);
  assert.match(consent, /code repository/i);
  assert.doesNotMatch(consent, /I will not write down what you said/);
});

test('consent and protocol give the same session length', () => {
  const minutes = (text) => [...text.matchAll(/(\d+) to (\d+)\s+minutes/g)].map((m) => `${m[1]}-${m[2]}`);
  assert.deepEqual(minutes(read('consent.md')), ['30-40']);
  assert.match(read('protocol.md'), /30 to 40\s+minutes/);
  assert.doesNotMatch(read('protocol.md'), /about 3[15] min/);
});
