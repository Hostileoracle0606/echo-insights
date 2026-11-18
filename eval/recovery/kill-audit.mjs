// kill.sh's helper: makes a throwaway user and notebook for one kill run,
// audits what landed after the relaunch, and writes recovery-kill.json.
//   node eval/recovery/kill-audit.mjs setup
//   node eval/recovery/kill-audit.mjs audit <userId> <case> <run> <delayMs> <found> <drained> <committedBeforeKill>
//   node eval/recovery/kill-audit.mjs delete <userId>
//   node eval/recovery/kill-audit.mjs sweep
//   node eval/recovery/kill-audit.mjs report <runs.jsonl> <simulator>
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { auditUser } from './audit.mjs';
import { localStack } from './local.mjs';
import { fixtures } from './stub-lambdas.mjs';

const T1 = fixtures.turns.t1.text;
const T2 = fixtures.turns.t2.text;
// Seeded so the notebook is one being continued: Lumen doesn't open with a
// greeting and the user has the floor at once.
export const SEED_ENTRY = 'Earlier note.';

export function classifyKill({ journal, turns, duplicates, committedBeforeKill, found = null }) {
  const count = (text) => journal.filter((t) => t === text).length;
  const kept = count(T1) >= 1 ? 1 : 0;
  let partial;
  if (!kept) partial = 'lost_completed';
  else if (count(T2) > 1 || count(T1) > 1) partial = 'duplicated';
  else if (count(T2) === 1) partial = 'recovered';
  // Any turn beyond turn 1 in the transcript is turn 2, whole or cut off.
  else partial = turns.some((t) => t !== T1) ? 'marked' : 'dropped';
  const duplicateTotal = Object.values(duplicates).reduce((a, b) => a + b, 0);
  const clean = kept === 1 && ['recovered', 'marked', 'dropped'].includes(partial) && duplicateTotal === 0;
  return {
    completed_turns_kept: { n: kept, of: 1 },
    partial_turn: partial,
    duplicates,
    // Nothing left to resume and turn 2 already whole: the kill missed the turn.
    outcome: committedBeforeKill || (found === 0 && partial === 'recovered') ? 'not_triggered' : clean ? 'pass' : 'fail',
  };
}

export function killReport(runs) {
  const out = {};
  for (const r of runs) {
    const c = (out[r.case] ??= { runs: 0, pass: 0, fail: 0, not_triggered: 0, error: 0, partial_turn: {} });
    c.runs += 1;
    c[r.outcome] += 1;
    if (r.partial_turn) c.partial_turn[r.partial_turn] = (c.partial_turn[r.partial_turn] ?? 0) + 1;
  }
  return out;
}

async function main([command, ...args]) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
  if (command === 'report') {
    const [file, simulator] = args;
    const runs = readFileSync(file, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line));
    const commit = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root }).toString().trim();
    const report = {
      version: 1, kind: 'simulator_kill', target: 'local', commit, simulator,
      recordedAt: new Date().toISOString(),
      method: 'integration_test/recovery_kill_test.dart killed with simctl terminate, relaunched to resume; see eval/recovery/README.md',
      summary: killReport(runs), runs,
    };
    const serialized = JSON.stringify(report, null, 2);
    if (/@example\.test|eyJ[A-Za-z0-9_-]{8,}/.test(serialized)) throw new Error('report contains forbidden content');
    const out = resolve(root, `eval/results/${report.recordedAt.slice(0, 10)}-${commit}/recovery-kill.json`);
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, `${serialized}\n`);
    console.log(relative(root, out));
    return;
  }

  const stack = localStack(process.env);
  if (!stack) throw new Error('source eval/privacy/local-env.sh first');
  if (command === 'setup') {
    const user = await stack.createUser();
    const now = new Date().toISOString();
    const notebook = await stack.insert('notebooks', { user_id: user.id, title: 'Recovery kill', started_at: now, conversation_mode: 'just_talk' });
    await stack.insert('journal_entries', { user_id: user.id, notebook_id: notebook.id, text: SEED_ENTRY, created_at: now });
    console.log(JSON.stringify({ userId: user.id, email: user.email, password: user.password, notebookId: notebook.id }));
  } else if (command === 'audit') {
    const [userId, killCase, run, delayMs, found, drained, committedBeforeKill] = args;
    const texts = async (table) => (await stack.call(`/rest/v1/${table}?select=text&user_id=eq.${userId}`)).map((r) => r.text);
    const { duplicates } = await auditUser({ url: stack.url, adminHeaders: stack.admin, userId });
    const result = classifyKill({
      journal: await texts('journal_entries'), turns: await texts('conversation_turns'),
      duplicates, committedBeforeKill: committedBeforeKill === 'true', found: found === '' ? null : Number(found),
    });
    console.log(JSON.stringify({
      case: killCase, run: Number(run), delay_ms: Number(delayMs),
      journal_checkpoints_at_relaunch: found === '' ? null : Number(found),
      drained: drained === 'true', ...result,
    }));
  } else if (command === 'delete') {
    await stack.deleteUser(args[0]);
  } else if (command === 'sweep') {
    console.log(`swept ${await stack.sweep()}`);
  } else {
    throw new Error(`unknown command ${command}`);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(String(error?.message ?? error));
    process.exit(1);
  });
}
