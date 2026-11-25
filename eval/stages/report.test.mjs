import assert from 'node:assert/strict';
import test from 'node:test';

import { attributionShares, renderReport } from './report.mjs';

const rows = [
  { worldId: 'w1', correct: false, stage: 'extraction' },
  { worldId: 'w1', correct: false, stage: 'retrieval' },
  { worldId: 'w2', correct: true, stage: null },
  { worldId: 'w2', correct: false, stage: 'extraction' },
  { worldId: 'w3', correct: false, stage: 'answer' },
];

test('attribution shares cover every miss and sum to 100%', () => {
  const shares = attributionShares(rows, { resamples: 200, seed: 1 });
  const total = Object.values(shares).reduce((n, s) => n + s.count, 0);
  assert.equal(total, 4);
  const pct = Object.values(shares).reduce((n, s) => n + s.share.value, 0);
  assert.ok(Math.abs(pct - 1) < 1e-9);
  assert.equal(shares.extraction.count, 2);
});

test('the report never prints a metric without its interval and sample size', () => {
  const summary = {
    synthetic: true, split: 'test', smoke: true, commit: 'abc1234', worlds: 3, queries: 5,
    metrics: {
      'Extraction · entity F1': { value: 0.8, lo: 0.7, hi: 0.9, n: 3, histories: 3 },
      'End to end · answer accuracy': { value: 0.2, lo: 0, hi: 0.5, n: 5, histories: 3 },
    },
    attribution: attributionShares(rows, { resamples: 200, seed: 1 }),
    latency: { extraction: { p50: 900, p95: 1500, n: 10 } },
  };
  const md = renderReport(summary);
  for (const name of Object.keys(summary.metrics)) {
    const line = md.split('\n').find((l) => l.includes(name));
    assert.ok(line && /\[.*–.*\]/.test(line) && /n = \d+/.test(line), `metric line for ${name}: ${line}`);
  }
  assert.match(md, /synthetic/i);
  assert.match(md, /Extraction.*50%/s, 'largest failing stage named with its share');
});
