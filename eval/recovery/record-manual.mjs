// Turns the hand-run sheet (eval/recovery/manual-sheet.md) into
// recovery-manual.json. Only enum outcomes and a short note survive: the
// sheet is published, so nothing a person said goes in it. Unfilled rows are
// reported as pending, never guessed.
//   node eval/recovery/record-manual.mjs [sheet.md]
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const TURN_OUTCOMES = ['recovered', 'marked', 'dropped', 'duplicated', 'lost_completed'];
export const CASES = Object.freeze({
  // Swipe the app away mid-turn on a physical iPhone, reopen it.
  physical_kill: TURN_OUTCOMES,
  // Airplane mode on mid-turn, off again after the turn should have saved.
  airplane_mode: TURN_OUTCOMES,
  // Talk over Lumen's spoken reply: only what was heard may be kept.
  interrupt_reply: ['heard_only', 'unheard_saved', 'reply_lost'],
});
const NOTE_MAX = 140;
const COLUMNS = ['case', 'run', 'date', 'device', 'outcome', 'duplicates', 'note'];

export function parseSheet(markdown) {
  const entries = [];
  const errors = [];
  let pending = 0;
  for (const [index, line] of markdown.split('\n').entries()) {
    if (!/^\s*\|/.test(line) || /^\s*\|\s*-/.test(line)) continue;
    const cells = line.trim().replace(/^\||\|$/g, '').split('|').map((c) => c.trim());
    if (cells[0] === 'case') continue; // header
    const row = Object.fromEntries(COLUMNS.map((name, i) => [name, cells[i] ?? '']));
    const where = `line ${index + 1}`;
    if (!row.outcome && !row.date && !row.device) {
      pending += 1;
      continue;
    }
    const outcomes = CASES[row.case];
    const problems = [];
    if (!outcomes) problems.push(`case "${row.case}" unknown`);
    else if (!outcomes.includes(row.outcome)) problems.push(`outcome "${row.outcome}" not one of ${outcomes.join('|')}`);
    if (!/^[1-3]$/.test(row.run)) problems.push('run must be 1, 2 or 3');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(row.date)) problems.push('date must be YYYY-MM-DD');
    if (!/^[A-Za-z0-9 .()-]{1,40}$/.test(row.device)) problems.push('device must be a short model name');
    if (!/^\d+$/.test(row.duplicates)) problems.push('duplicates must be a count');
    if (row.note.length > NOTE_MAX) problems.push(`note longer than ${NOTE_MAX} characters`);
    if (problems.length) {
      errors.push(`${where}: ${problems.join('; ')}`);
      continue;
    }
    entries.push({ ...row, run: Number(row.run), duplicates: Number(row.duplicates) });
  }
  return { entries, pending, errors };
}

function main() {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const sheetPath = resolve(process.argv[2] ?? resolve(root, 'eval/recovery/manual-sheet.md'));
  const { entries, pending, errors } = parseSheet(readFileSync(sheetPath, 'utf8'));
  if (errors.length) {
    for (const error of errors) console.error(error);
    process.exit(1);
  }
  const commit = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root }).toString().trim();
  const summary = Object.fromEntries(Object.keys(CASES).map((name) => {
    const rows = entries.filter((e) => e.case === name);
    const outcomes = {};
    for (const e of rows) outcomes[e.outcome] = (outcomes[e.outcome] ?? 0) + 1;
    return [name, { runs: rows.length, outcomes, duplicates: rows.reduce((n, e) => n + e.duplicates, 0) }];
  }));
  const report = { version: 1, kind: 'manual', commit, recordedAt: new Date().toISOString(), pending, summary, entries };
  const out = resolve(root, `eval/results/${report.recordedAt.slice(0, 10)}-${commit}/recovery-manual.json`);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, `${JSON.stringify(report, null, 2)}\n`);
  console.log(`${relative(root, out)}: ${entries.length} entries, ${pending} pending`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
