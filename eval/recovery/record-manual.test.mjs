import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseSheet, CASES } from './record-manual.mjs';

const sheet = (rows) => `# Sheet

Some prose that is not a table.

| case | run | date | device | outcome | duplicates | note |
|---|---|---|---|---|---|---|
${rows.join('\n')}
`;

test('a filled row becomes an entry', () => {
  const { entries, pending, errors } = parseSheet(sheet([
    '| physical_kill | 1 | 2026-11-20 | iPhone 15 | recovered | 0 | killed from the app switcher mid-extraction |',
  ]));
  assert.deepEqual(errors, []);
  assert.equal(pending, 0);
  assert.deepEqual(entries, [{
    case: 'physical_kill', run: 1, date: '2026-11-20', device: 'iPhone 15',
    outcome: 'recovered', duplicates: 0, note: 'killed from the app switcher mid-extraction',
  }]);
});

test('an unknown outcome is rejected', () => {
  const { entries, errors } = parseSheet(sheet(['| airplane_mode | 1 | 2026-11-20 | iPhone 15 | mostly_fine | 0 | |']));
  assert.equal(entries.length, 0);
  assert.match(errors[0], /outcome/);
});

test('an outcome from another case is rejected', () => {
  const { errors } = parseSheet(sheet(['| interrupt_reply | 1 | 2026-11-20 | iPhone 15 | recovered | 0 | |']));
  assert.match(errors[0], /outcome/);
});

test('a note longer than 140 characters is rejected', () => {
  const { errors } = parseSheet(sheet([`| physical_kill | 2 | 2026-11-20 | iPhone 15 | marked | 0 | ${'x'.repeat(141)} |`]));
  assert.match(errors[0], /note/);
});

test('bad run, date, duplicates and case are each rejected', () => {
  const { errors } = parseSheet(sheet([
    '| physical_kill | 4 | 2026-11-20 | iPhone 15 | recovered | 0 | |',
    '| physical_kill | 1 | 20/11/2026 | iPhone 15 | recovered | 0 | |',
    '| physical_kill | 1 | 2026-11-20 | iPhone 15 | recovered | -1 | |',
    '| shake_phone | 1 | 2026-11-20 | iPhone 15 | recovered | 0 | |',
  ]));
  assert.equal(errors.length, 4);
});

test('an unfilled row is pending, never an entry', () => {
  const { entries, pending, errors } = parseSheet(sheet(['| physical_kill | 3 |  |  |  |  |  |']));
  assert.deepEqual([entries.length, pending, errors.length], [0, 1, 0]);
});

test('three cases, as the spec names them', () => {
  assert.deepEqual(Object.keys(CASES), ['physical_kill', 'airplane_mode', 'interrupt_reply']);
});

test('only the sheet table counts, not other tables in the document', () => {
  const doc = `| outcome | meaning |\n|---|---|\n| \`recovered\` | turn 2 once |\n\n${sheet(['| physical_kill | 1 |  |  |  |  |  |'])}`;
  const { entries, pending, errors } = parseSheet(doc);
  assert.deepEqual([entries.length, pending, errors.length], [0, 1, 0]);
});
