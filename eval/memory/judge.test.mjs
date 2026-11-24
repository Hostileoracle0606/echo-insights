import assert from 'node:assert/strict';
import test from 'node:test';

import {
  BRIEF_SCHEMA, JUDGE_MODEL, JudgeUnavailable, PROBE_SCHEMA, applyVerdict, ask, briefInput, cacheKey,
  normalizeProbeVerdict, probeInput, scriptOf,
} from './judge.mjs';

const felix = {
  id: 'correction-edit-description',
  sessions: [
    { turns: ["Had coffee with Felix Navarro, he's a pediatric nurse at Saint Corin hospital."] },
    { turns: ['Felix invited me to his birthday dinner on Friday.'] },
  ],
  actions: [{ after_session: 1, kind: 'correct', name: 'Felix Navarro', description: 'Felix Navarro is a physical therapist.' }],
  probes: [{ ask: 'What does Felix do for work?', expect_retrieved: ['Felix Navarro'], expect_status: 'decided', stale_text: ['pediatric nurse'] }],
};

const fakeClient = (reply) => {
  const calls = [];
  return {
    calls,
    beta: { messages: { create: async (body) => { calls.push(body); return reply(body); } } },
  };
};
const textReply = (obj, extra = {}) => ({ stop_reason: 'end_turn', model: JUDGE_MODEL, usage: {}, content: [{ type: 'text', text: JSON.stringify(obj) }], ...extra });

test('scriptOf places user memory actions after the session they follow', () => {
  const lines = scriptOf(felix).split('\n');
  const edit = lines.findIndex((l) => l.includes('edited the memory of "Felix Navarro"'));
  assert.ok(edit > lines.indexOf('Session 1:') && edit < lines.indexOf('Session 2:'));
});

test('probeInput leaves background distractors out but keeps their rank gaps', () => {
  const { text } = probeInput(felix, felix.probes[0], {
    retrieved: [
      { name: 'Crossword Puzzles', text: 'Weekend crosswords.', background: true },
      { name: 'Felix Navarro', text: 'Felix Navarro is a physical therapist.', background: false },
    ],
  }, { stale: false });
  assert.doesNotMatch(text, /Crossword/);
  assert.match(text, /#2 Felix Navarro/);
});

test('probeInput marks only the checks the probe makes as applicable', () => {
  const { checks, text } = probeInput(felix, felix.probes[0], { retrieved: [] }, { stale: false });
  assert.deepEqual(checks, { stale: true, status: true, order: false, ambiguity: false });
  assert.match(text, /No longer current per the script: pediatric nurse/);
  assert.match(text, /order: not applicable/);
});

test('a vacuous stale check (rule stale === null) is not sent to the judge as applicable', () => {
  const { checks } = probeInput(felix, felix.probes[0], { retrieved: [] }, { stale: null });
  assert.equal(checks.stale, false);
});

test('briefInput names every outdated fact from all probes once', () => {
  const text = briefInput({ ...felix, probes: [...felix.probes, { ask: 'x', stale_text: ['pediatric nurse'] }] }, 'Felix is a nurse.');
  assert.equal(text.match(/pediatric nurse/g).length, 2); // once in the script, once in the list
});

test('normalizeProbeVerdict forces n/a on checks the probe does not make', () => {
  const v = normalizeProbeVerdict({ stale: 'stale', status: 'correct', order: 'kept', ambiguity: 'n/a' }, { stale: true, status: false, order: false, ambiguity: true });
  assert.deepEqual([v.stale, v.status, v.order, v.ambiguity], ['stale', 'n/a', 'n/a', 'unjudged']);
});

test('applyVerdict replaces rule fields and keeps brief staleness per scenario', () => {
  const row = { stale: false, staleIn: [], status: 'wrong', order: 'n/a', ambiguity: 'n/a', briefChecked: true };
  const judged = applyVerdict(row, { stale: 'clean', status: 'correct', order: 'n/a', ambiguity: 'n/a' }, true);
  assert.deepEqual([judged.stale, judged.staleIn, judged.status], [true, ['brief'], 'correct']);
  const notApplicable = applyVerdict({ ...row, stale: null }, { stale: 'n/a', status: 'n/a', order: 'n/a', ambiguity: 'n/a' }, true);
  assert.equal(notApplicable.stale, null);
  assert.deepEqual(notApplicable.staleIn, []);
});

test('an unjudged applicable check counts against Lumen, never for it', () => {
  const judged = applyVerdict({ stale: false, staleIn: [] }, { stale: 'clean', status: 'unjudged', order: 'unjudged', ambiguity: 'unjudged' }, false);
  assert.deepEqual([judged.status, judged.order, judged.ambiguity], ['wrong', 'lost', 'missed']);
});

test('ask sends Claude Opus 5.5 a JSON-schema format with refusal fallback and parses the verdict', async () => {
  const client = fakeClient(() => textReply({ stale: 'clean', reason: 'ok' }));
  const { verdict, model } = await ask(client, 'hello', BRIEF_SCHEMA);
  assert.deepEqual(verdict, { stale: 'clean', reason: 'ok' });
  assert.equal(model, JUDGE_MODEL);
  const body = client.calls[0];
  assert.equal(body.model, 'claude-opus-5-5');
  assert.equal(body.fallbacks, 'default');
  assert.deepEqual(body.output_config.format, { type: 'json_schema', schema: BRIEF_SCHEMA });
});

test('ask throws JudgeUnavailable on refusal and on truncation instead of guessing', async () => {
  await assert.rejects(ask(fakeClient(() => textReply({}, { stop_reason: 'refusal', stop_details: { category: 'cyber' } })), 'x', PROBE_SCHEMA), JudgeUnavailable);
  await assert.rejects(ask(fakeClient(() => textReply({}, { stop_reason: 'max_tokens' })), 'x', PROBE_SCHEMA), JudgeUnavailable);
});

test('cacheKey changes with the input and is stable otherwise', () => {
  assert.equal(cacheKey('probe', 'a'), cacheKey('probe', 'a'));
  assert.notEqual(cacheKey('probe', 'a'), cacheKey('probe', 'b'));
  assert.notEqual(cacheKey('probe', 'a'), cacheKey('brief', 'a'));
});
