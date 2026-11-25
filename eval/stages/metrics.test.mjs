import assert from 'node:assert/strict';
import test from 'node:test';

import { mrr, ndcgAt, percentile, prf, recallAt } from './metrics.mjs';

const close = (a, b, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, `${a} vs ${b}`);

test('prf: precision, recall and F1, with 0 for empty denominators', () => {
  assert.deepEqual(prf(3, 1, 2), { precision: 0.75, recall: 0.6, f1: 2 * 0.75 * 0.6 / 1.35 });
  assert.deepEqual(prf(0, 0, 0), { precision: 0, recall: 0, f1: 0 });
});

test('recall@k counts gold ids found in the first k', () => {
  const ranked = ['x', 'a', 'y', 'b', 'z'];
  assert.equal(recallAt(ranked, ['a', 'b'], 1), 0);
  assert.equal(recallAt(ranked, ['a', 'b'], 2), 0.5);
  assert.equal(recallAt(ranked, ['a', 'b'], 5), 1);
  assert.equal(recallAt(ranked, [], 5), null, 'no gold: not scored');
});

test('MRR is 1 / rank of the first gold item, 0 if none', () => {
  assert.equal(mrr(['x', 'y', 'a'], ['a']), 1 / 3);
  assert.equal(mrr(['x'], ['a']), 0);
});

test('NDCG@10 with graded gold matches the closed form (gain 2^rel - 1, log2 discount)', () => {
  const ranked = ['x', 'a', 'y', 'z', 'b'];
  const gold = [{ entityId: 'a', relevance: 2 }, { entityId: 'b', relevance: 1 }];
  const dcg = 3 / Math.log2(3) + 1 / Math.log2(6);
  const idcg = 3 / Math.log2(2) + 1 / Math.log2(3);
  close(ndcgAt(ranked, gold, 10), dcg / idcg);
  assert.equal(ndcgAt(['a', 'b'], gold, 10), 1);
});

test('percentile is nearest-rank', () => {
  const v = Array.from({ length: 20 }, (_, i) => i + 1);
  assert.equal(percentile(v, 50), 10);
  assert.equal(percentile(v, 95), 19);
});
