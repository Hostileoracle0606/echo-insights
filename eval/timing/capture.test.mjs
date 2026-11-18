import { test } from 'node:test';
import assert from 'node:assert/strict';
import { annotate } from './capture.mjs';
import { parseRun } from './parse.mjs';

const app = (o) => `flutter: [lumen-timing] ${JSON.stringify({ v: 1, mode: 'debug', ...o })}`;

test('keeps only timing lines and adds the host launch→first_frame span', () => {
  const out = annotate([
    { text: 'engine banner', at: 10 },
    { text: app({ stage: 'process_start', phase: 'mark', t_ms: 0 }), at: 900 },
    { text: app({ stage: 'first_frame', phase: 'mark', t_ms: 300 }), at: 1210.6 },
  ], { launchedAt: 0 });
  const { marks } = parseRun(out, { allowDebug: true });
  assert.deepEqual(marks.map((m) => m.stage), ['process_start', 'first_frame', 'launch_to_first_frame_host']);
  assert.deepEqual(marks[2], {
    v: 1, stage: 'launch_to_first_frame_host', phase: 'span', t_ms: 1211, dur_ms: 1211, mode: 'debug',
  });
  assert.ok(!out.includes('engine banner'));
});

test('no first_frame within the window: no host span is invented', () => {
  const out = annotate([{ text: app({ stage: 'process_start', phase: 'mark', t_ms: 0 }), at: 5 }], { launchedAt: 0 });
  assert.deepEqual(parseRun(out, { allowDebug: true }).marks.map((m) => m.stage), ['process_start']);
});
