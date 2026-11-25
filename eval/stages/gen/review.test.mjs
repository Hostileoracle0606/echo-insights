import assert from 'node:assert/strict';
import test from 'node:test';

import { recordReview, reviewPage, reviewSample } from './review.mjs';
import { makeWorld } from './world.mjs';

// Records shaped like worlds.jsonl, with trivially "written" text.
const records = Array.from({ length: 40 }, (_, i) => {
  const world = makeWorld({ seed: 20001 + i, split: 'test' });
  return {
    world,
    written: {
      turns: world.sessions.flatMap((s, j) => (s.facts.length ? [{ session: j + 1, text: s.facts.map((f) => f.statement).join(' '), factIds: s.facts.map((f) => f.id) }] : [])),
      queries: world.queries.map((q) => ({ id: q.id, text: q.intent })),
    },
  };
});

test('the sample has at most 10 items per family and is deterministic per seed', () => {
  const a = reviewSample(records, { perFamily: 10, seed: 1 });
  const b = reviewSample(records, { perFamily: 10, seed: 1 });
  assert.deepEqual(a, b);
  const perFamily = {};
  for (const item of a) perFamily[item.family] = (perFamily[item.family] ?? 0) + 1;
  for (const n of Object.values(perFamily)) assert.ok(n <= 10);
  assert.notDeepEqual(reviewSample(records, { perFamily: 10, seed: 2 }).map((x) => x.queryId), a.map((x) => x.queryId));
});

test('each sampled item shows the conversation, the question, and the gold labels by name', () => {
  const [item] = reviewSample(records, { perFamily: 1, seed: 1 });
  assert.ok(item.turns.length > 0 && item.question && item.answer);
  for (const g of item.gold) assert.ok(typeof g.name === 'string' && g.name.length > 0);
});

test('recordReview tallies per family and rejects ids outside the sample', () => {
  const sample = reviewSample(records, { perFamily: 2, seed: 1 });
  const verdicts = Object.fromEntries(sample.map((s, i) => [s.queryId, { verdict: i === 0 ? 'wrong' : 'ok', note: '' }]));
  const out = recordReview(sample, verdicts);
  assert.equal(out.wrongIds.length, 1);
  const totals = Object.values(out.perFamily).reduce((n, f) => n + f.of, 0);
  assert.equal(totals, sample.length);
  assert.throws(() => recordReview(sample, { ...verdicts, 'not-in-sample': { verdict: 'ok' } }), /not in the sample/);
  assert.throws(() => recordReview(sample, { [sample[0].queryId]: { verdict: 'maybe' } }), /verdict/);
});

test('the review page embeds the sample and is labelled synthetic', () => {
  const html = reviewPage(reviewSample(records, { perFamily: 1, seed: 1 }));
  assert.match(html, /synthetic/i);
  assert.match(html, /<script>/);
  assert.ok(!html.includes('</script><script'), 'sample JSON cannot break out of its script tag');
});
