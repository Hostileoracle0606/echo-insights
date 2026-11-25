import assert from 'node:assert/strict';
import test from 'node:test';

import { bootstrap, pairedBootstrap } from './stats.mjs';

// 30 histories with 1-5 queries each; `hit` alternates by history.
const items = [];
for (let h = 0; h < 30; h += 1) for (let q = 0; q <= h % 5; q += 1) items.push({ history: `h${h}`, hit: h % 3 === 0 ? 1 : 0, a: q % 2, b: q % 2 });
const mean = (xs) => xs.reduce((n, x) => n + x.hit, 0) / xs.length;

test('the point value is the metric on all items, inside its interval', () => {
  const r = bootstrap({ items, groupKey: (x) => x.history, metric: mean, resamples: 500, seed: 1 });
  assert.equal(r.value, mean(items));
  assert.ok(r.lo <= r.value && r.value <= r.hi);
  assert.equal(r.histories, 30);
  assert.equal(r.n, items.length);
});

test('the same seed gives the same interval', () => {
  const a = bootstrap({ items, groupKey: (x) => x.history, metric: mean, resamples: 300, seed: 7 });
  const b = bootstrap({ items, groupKey: (x) => x.history, metric: mean, resamples: 300, seed: 7 });
  assert.deepEqual(a, b);
});

test('every resample contains whole histories, never part of one', () => {
  const size = new Map();
  for (const x of items) size.set(x.history, (size.get(x.history) ?? 0) + 1);
  const whole = (xs) => {
    const count = new Map();
    for (const x of xs) count.set(x.history, (count.get(x.history) ?? 0) + 1);
    return [...count].every(([h, n]) => n % size.get(h) === 0) ? 1 : 0;
  };
  const r = bootstrap({ items, groupKey: (x) => x.history, metric: whole, resamples: 300, seed: 3 });
  assert.equal(r.lo, 1);
});

test('a paired comparison of identical metrics is exactly zero', () => {
  const r = pairedBootstrap({ items, groupKey: (x) => x.history, a: (xs) => mean(xs), b: (xs) => mean(xs), resamples: 300, seed: 1 });
  assert.deepEqual([r.diff, r.lo, r.hi], [0, 0, 0]);
});

test('a paired comparison detects a consistent difference', () => {
  const r = pairedBootstrap({ items, groupKey: (x) => x.history, a: (xs) => mean(xs) + 0.1, b: mean, resamples: 300, seed: 1 });
  assert.ok(r.lo > 0.09 && r.hi < 0.11);
});
