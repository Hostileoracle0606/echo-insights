import { test } from 'node:test';
import assert from 'node:assert/strict';
import { combine, percentile, summarize, summarizeDir } from './summarize.mjs';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const m = (o) => ({ v: 1, mode: 'profile', ...o });
const meta = { device: 'iPhone 15 (A16)', mode: 'profile', network: 'wifi', history: 50 };

test('nearest-rank percentiles', () => {
  const values = Array.from({ length: 20 }, (_, i) => i + 1);
  assert.equal(percentile(values, 50), 10);
  assert.equal(percentile(values, 95), 19);
  assert.equal(percentile([7], 95), 7);
  assert.equal(percentile([3, 1, 2], 50), 2); // unsorted input
  assert.equal(percentile([], 50), null);
});

test('point marks use t_ms; spans and ends use dur_ms', () => {
  const marks = [
    m({ run: 1, stage: 'first_frame', phase: 'mark', t_ms: 400 }),
    m({ run: 2, stage: 'first_frame', phase: 'mark', t_ms: 500 }),
    m({ run: 1, stage: 'retrieval', phase: 'span', t_ms: 900, dur_ms: 80 }),
    m({ run: 1, stage: 'notebook_open', phase: 'begin', t_ms: 10 }),
    m({ run: 1, stage: 'notebook_open', phase: 'end', t_ms: 40, dur_ms: 30 }),
  ];
  const s = summarize(marks, meta);
  assert.deepEqual(s.stages.first_frame, { n: 2, p50: 400, p95: 500, incomplete: 0, failed: 0 });
  assert.equal(s.stages.retrieval.p50, 80);
  assert.equal(s.stages.notebook_open.p50, 30);
  assert.deepEqual(s.meta, meta);
});

test('incomplete stages are counted, never dropped', () => {
  const marks = [
    // begin with no end (crash or cancel)
    m({ run: 1, stage: 'notebook_open', phase: 'begin', t_ms: 10 }),
    // a re-begin before the end: the first one is incomplete
    m({ run: 2, stage: 'user_turn_end_to_first_audio', phase: 'begin', t_ms: 1 }),
    m({ run: 2, stage: 'user_turn_end_to_first_audio', phase: 'begin', t_ms: 5 }),
    m({ run: 2, stage: 'user_turn_end_to_first_audio', phase: 'end', t_ms: 9, dur_ms: 4 }),
    // end without begin
    m({ run: 3, stage: 'commit', phase: 'end', t_ms: 9, incomplete: true }),
  ];
  const s = summarize(marks, meta);
  assert.deepEqual(s.stages.notebook_open, { n: 0, p50: null, p95: null, incomplete: 1, failed: 0 });
  assert.equal(s.stages.user_turn_end_to_first_audio.incomplete, 1);
  assert.equal(s.stages.user_turn_end_to_first_audio.n, 1);
  assert.equal(s.stages.commit.incomplete, 1);
});

test('a begin in one run never pairs with an end in another', () => {
  const marks = [
    m({ run: 1, stage: 'notebook_open', phase: 'begin', t_ms: 10 }),
    m({ run: 2, stage: 'notebook_open', phase: 'end', t_ms: 40, dur_ms: 30, incomplete: true }),
  ];
  assert.equal(summarize(marks, meta).stages.notebook_open.incomplete, 2);
});

test('failed calls are counted and kept out of the percentiles', () => {
  const marks = [
    m({ run: 1, stage: 'retrieval_server', phase: 'span', t_ms: 1, dur_ms: 900, ok: true }),
    m({ run: 1, stage: 'retrieval_server', phase: 'span', t_ms: 2, dur_ms: 3, ok: false }),
  ];
  const s = summarize(marks, meta).stages.retrieval_server;
  assert.deepEqual([s.n, s.p50, s.failed], [1, 900, 1]);
});

test('overlap rate: how often background work ran during a live session', () => {
  const marks = [
    m({ run: 1, stage: 'opening_prep', phase: 'span', t_ms: 1, dur_ms: 5, overlap: true }),
    m({ run: 1, stage: 'opening_prep', phase: 'span', t_ms: 2, dur_ms: 5, overlap: false }),
    m({ run: 1, stage: 'notebook_open', phase: 'end', t_ms: 3, dur_ms: 5, overlap: false, incomplete: true }),
  ];
  // Per stage: pooling notebook_open with opening_prep would dilute the rate.
  assert.deepEqual(summarize(marks, meta).overlapRate, { opening_prep: [1, 2], notebook_open: [0, 1] });
});

test('simulator and device inputs refuse to merge', () => {
  const sim = { marks: [], meta: { ...meta, device: 'iPhone 17 Pro simulator', mode: 'debug' } };
  const dev = { marks: [], meta };
  assert.throws(() => combine([sim, dev]), /device|mode/);
  const wifi = { marks: [], meta };
  const lte = { marks: [], meta: { ...meta, network: 'lte' } };
  assert.throws(() => combine([wifi, lte]), /network/);
  const runs = combine([{ marks: [m({ stage: 'x', phase: 'mark', t_ms: 1 })], meta }, { marks: [m({ stage: 'x', phase: 'mark', t_ms: 2 })], meta }]);
  assert.deepEqual(runs.marks.map((x) => x.run), [1, 2]);
});

test('a results dir summarizes per group, labelled by its meta.json', () => {
  const dir = mkdtempSync(join(tmpdir(), 'timing-'));
  const line = (o) => `[lumen-timing] ${JSON.stringify({ v: 1, mode: 'debug', ...o })}\n`;
  writeFileSync(join(dir, 'sim-cold-0-1.jsonl'), line({ stage: 'first_frame', phase: 'mark', t_ms: 300 }));
  writeFileSync(join(dir, 'sim-cold-0-2.jsonl'), line({ stage: 'first_frame', phase: 'mark', t_ms: 500 }));
  writeFileSync(join(dir, 'retrieval-0-1.jsonl'),
    `[lumen-timing] ${JSON.stringify({ v: 1, mode: 'node', stage: 'retrieval_server', phase: 'span', t_ms: 1, dur_ms: 9, ok: true })}\n`);
  writeFileSync(join(dir, 'meta.json'), JSON.stringify({
    'sim-cold-0': { device: 'iPhone 17 Pro simulator', mode: 'debug', network: 'host loopback', history: 0 },
    'retrieval-0': { device: 'Node 20 → local stack', mode: 'node', network: 'host loopback', history: 0 },
  }));
  const out = summarizeDir(dir);
  assert.deepEqual(out.groups['sim-cold-0'].stages.first_frame.n, 2);
  assert.equal(out.groups['sim-cold-0'].runs, 2);
  assert.equal(out.groups['retrieval-0'].stages.retrieval_server.p50, 9);
  assert.equal(out.groups['retrieval-0'].meta.history, 0);
});

test('a group without meta is refused: every figure states its device and mode', () => {
  const dir = mkdtempSync(join(tmpdir(), 'timing-'));
  writeFileSync(join(dir, 'mystery-1.jsonl'), '');
  writeFileSync(join(dir, 'meta.json'), '{}');
  assert.throws(() => summarizeDir(dir), /meta/);
});
