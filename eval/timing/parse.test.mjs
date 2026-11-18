import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseRun } from './parse.mjs';

const line = (o) => `[lumen-timing] ${JSON.stringify({ v: 1, mode: 'profile', ...o })}`;

test('mixed log text yields only timing marks', () => {
  const text = [
    'Some engine banner',
    `flutter: ${line({ stage: 'process_start', phase: 'mark', t_ms: 0 })}`,
    '[voice][session] status → live',
    line({ stage: 'first_frame', phase: 'mark', t_ms: 412 }),
    '',
  ].join('\n');
  const { marks, rejected } = parseRun(text);
  assert.deepEqual(marks.map((m) => m.stage), ['process_start', 'first_frame']);
  assert.equal(marks[1].t_ms, 412);
  assert.equal(rejected, 0);
});

test('CRLF line endings from a pty are handled', () => {
  const text = `${line({ stage: 'first_frame', phase: 'mark', t_ms: 3 })}\r\n`;
  assert.equal(parseRun(text).marks.length, 1);
});

test('a debug-mode mark throws unless debug is explicitly allowed', () => {
  const text = line({ stage: 'first_frame', phase: 'mark', t_ms: 1, mode: 'debug' });
  assert.throws(() => parseRun(text), /debug/);
  assert.equal(parseRun(text, { allowDebug: true }).marks[0].mode, 'debug');
});

test('a run mixing build modes is refused even with debug allowed', () => {
  const text = [
    line({ stage: 'a', phase: 'mark', t_ms: 1, mode: 'debug' }),
    line({ stage: 'b', phase: 'mark', t_ms: 2, mode: 'profile' }),
  ].join('\n');
  assert.throws(() => parseRun(text, { allowDebug: true }), /mode/);
});

test('a malformed JSON line is counted in rejected, not thrown', () => {
  const text = [
    '[lumen-timing] {"v":1,"stage":"first_fr',
    line({ stage: 'first_frame', phase: 'mark', t_ms: 5 }),
  ].join('\n');
  const { marks, rejected } = parseRun(text);
  assert.equal(marks.length, 1);
  assert.equal(rejected, 1);
});

test('a line missing stage, phase or numeric t_ms is rejected', () => {
  const text = [
    line({ phase: 'mark', t_ms: 1 }),
    line({ stage: 'x', t_ms: 1 }),
    line({ stage: 'x', phase: 'mark', t_ms: '1' }),
  ].join('\n');
  assert.deepEqual(parseRun(text), { marks: [], rejected: 3 });
});

test('a string-valued field is rejected: marks are content-free', () => {
  const text = line({ stage: 'retrieval', phase: 'span', t_ms: 9, dur_ms: 4, scope: 'Maya' });
  assert.deepEqual(parseRun(text), { marks: [], rejected: 1 });
});
