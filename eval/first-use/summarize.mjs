// First-use study summary: `node eval/first-use/summarize.mjs`.
// Reads every recorded session (eval/results/*/first-use/P<n>.json) and writes
// eval/results/<date>-<sha>/first-use.json. Counts only ("2 of 4"), never
// percentages: with 3-5 people a percentage claims more than the study can.
// Notes and unapproved quotes never reach the summary.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { COMPLETION, CONFUSION_CODES, QUESTIONS, SCORES, TASKS, recordedSessions, validateSession } from './record.mjs';

const countOf = (sessions, values, pick) => ({
  ...Object.fromEntries(values.map((v) => [v, sessions.filter((s) => pick(s) === v).length])),
  of: sessions.length,
});

function median(sorted) {
  if (!sorted.length) return null;
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

export function summarize(sessions) {
  if (!sessions.length) throw new Error('no sessions to summarize');
  const seen = new Set();
  for (const session of sessions) {
    validateSession(session);
    if (seen.has(session.participant)) throw new Error(`${session.participant} appears more than once`);
    seen.add(session.participant);
  }
  const n = sessions.length;
  const times = sessions.map((s) => s.secondsToFirstTurn).filter((t) => t !== null).sort((a, b) => a - b);

  return {
    participants: n,
    timeToFirstTurn: {
      reached: times.length,
      of: n,
      medianSeconds: median(times),
      minSeconds: times.length ? times[0] : null,
      maxSeconds: times.length ? times.at(-1) : null,
      byMode: {
        voice: sessions.filter((s) => s.firstTurnMode === 'voice').length,
        typed: sessions.filter((s) => s.firstTurnMode === 'typed').length,
      },
    },
    tasks: Object.fromEntries(TASKS.map((task) => [task, countOf(sessions, COMPLETION, (s) => s.tasks[task])])),
    confusions: Object.fromEntries(CONFUSION_CODES.map((code) => [code, {
      moments: sessions.reduce((sum, s) => sum + s.confusions.filter((c) => c.code === code).length, 0),
      participants: sessions.filter((s) => s.confusions.some((c) => c.code === code)).length,
      of: n,
    }])),
    comprehension: Object.fromEntries(QUESTIONS.map((q) => [q, countOf(sessions, SCORES, (s) => s.comprehension[q])])),
    quotes: sessions
      .flatMap((s) => s.quotes.filter((q) => q.approved === true).map((q) => ({ participant: s.participant, text: q.text })))
      .sort((a, b) => a.participant.localeCompare(b.participant)),
  };
}

export function summaryPath(date, sha) {
  return `eval/results/${date.toISOString().slice(0, 10)}-${sha}/first-use.json`;
}

function main() {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  const sources = recordedSessions(root).sort();
  const sessions = sources.map((path) => JSON.parse(readFileSync(resolve(root, path), 'utf8')));
  let summary;
  try {
    summary = summarize(sessions);
  } catch (error) {
    console.error(`first-use summary: ${error.message}`);
    process.exit(1);
  }
  const commit = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root }).toString().trim();
  const report = { version: 1, study: 'first-use', commit, generatedAt: new Date().toISOString(), sources, ...summary };
  const out = summaryPath(new Date(), commit);
  mkdirSync(dirname(resolve(root, out)), { recursive: true });
  writeFileSync(resolve(root, out), `${JSON.stringify(report, null, 2)}\n`);
  const t = summary.timeToFirstTurn;
  console.log(`${summary.participants} participants; first turn reached by ${t.reached} of ${t.of}` +
    (t.reached ? `, median ${t.medianSeconds}s (range ${t.minSeconds}-${t.maxSeconds}s)` : ''));
  for (const task of TASKS) {
    const c = summary.tasks[task];
    console.log(`${task}: ${c.yes} of ${c.of} unaided, ${c.with_help} with help, ${c.no} not done`);
  }
  console.log(`→ ${out}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
