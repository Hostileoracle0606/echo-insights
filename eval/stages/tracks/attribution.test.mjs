import assert from 'node:assert/strict';
import test from 'node:test';

import { PROMPT_SHA256, productionAnswerPrompt } from './answer-prompt.mjs';
import { attribute, finalCorrect } from './attribution.mjs';

const base = { answers: ['b'], extracted: ['a', 'b'], stored: ['a', 'b'], top10: ['b'], correct: false, answerable: true };

test('a correct answer has no failing stage', () => {
  assert.equal(attribute({ ...base, correct: true }), null);
});

test('the first stage that lost the answering entity is blamed, in pipeline order', () => {
  assert.equal(attribute({ ...base, extracted: ['a'], stored: ['a'], top10: [] }), 'extraction');
  assert.equal(attribute({ ...base, stored: ['a'], top10: [] }), 'admission');
  assert.equal(attribute({ ...base, top10: ['a'] }), 'retrieval');
  assert.equal(attribute(base), 'answer');
});

test('an unanswerable question answered anyway is an answer-stage failure', () => {
  assert.equal(attribute({ ...base, answers: [], answerable: false, correct: false }), 'answer');
});

test('correctness: answerable needs "correct", unanswerable needs "abstained"', () => {
  assert.equal(finalCorrect('correct', true), true);
  assert.equal(finalCorrect('abstained', true), false);
  assert.equal(finalCorrect('abstained', false), true);
  assert.equal(finalCorrect('correct', false), false);
});

test('the answer prompt is read from the app source, and a change to it is caught', () => {
  const prompt = productionAnswerPrompt();
  assert.match(prompt.text, /You are Lumen/);
  // If this fails, the app's Live prompt changed: re-read it, confirm the
  // end-to-end track still reflects production, then update PROMPT_SHA256.
  assert.equal(prompt.sha256, PROMPT_SHA256);
});

test('the memory tool declaration matches the one the app gives Gemini Live', async () => {
  const { readFileSync } = await import('node:fs');
  const { MEMORY_TOOL } = await import('./answer-prompt.mjs');
  const dart = readFileSync(new URL('../../../lib/providers/journal_provider.dart', import.meta.url), 'utf8');
  assert.equal(MEMORY_TOOL.name, 'get_relevant_memory');
  assert.ok(dart.includes(`'name': '${MEMORY_TOOL.name}'`));
  assert.ok(dart.includes(MEMORY_TOOL.description), 'tool description drifted from journal_provider.dart');
  assert.ok(dart.includes(MEMORY_TOOL.parameters.properties.query.description));
});
