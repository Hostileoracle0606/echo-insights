import assert from 'node:assert/strict';
import test from 'node:test';

import { dedupe, jaccard, leakageReport, normalize, shared8gram } from './leakage.mjs';

test('normalize lowercases, strips accents and punctuation', () => {
  assert.equal(normalize('Où est   Noël, l’ami?'), 'ou est noel l ami');
});

test('near-duplicates (Jaccard >= 0.8) are flagged across splits, for turns and questions', () => {
  const report = leakageReport(
    [{ id: 't1', kind: 'turn', text: 'My sister Ilse just moved to Saltcote last week' }],
    [{ id: 'o1', kind: 'turn', text: 'my sister ilse just moved to saltcote last week!' }],
  );
  assert.equal(report.length, 1);
  assert.equal(report[0].reason, 'near-duplicate');
  assert.ok(jaccard('a b c d', 'a b c e') < 0.8);
});

test('a shared 8-word sequence is flagged between questions, not between turns', () => {
  const eight = 'where does she live now that she has';
  assert.equal(shared8gram(`so ${eight} moved`, `hey ${eight} left`), true);
  const q = leakageReport([{ id: 'q1', kind: 'query', text: `so ${eight} moved` }], [{ id: 'q2', kind: 'query', text: `hey ${eight} left town for good` }]);
  assert.deepEqual(q.map((r) => r.reason), ['shared 8-gram']);
  const t = leakageReport([{ id: 't1', kind: 'turn', text: `so ${eight} moved` }], [{ id: 't2', kind: 'turn', text: `hey ${eight} left town for good` }]);
  assert.deepEqual(t, []);
});

test('dedupe keeps the first of near-identical items within a split', () => {
  const kept = dedupe([
    { id: 'a', kind: 'query', text: 'Where did Kiran grow up?' },
    { id: 'b', kind: 'query', text: 'where did kiran grow up' },
    { id: 'c', kind: 'query', text: 'What does Hamish do for work?' },
  ]);
  assert.deepEqual(kept.map((x) => x.id), ['a', 'c']);
});
