// Per-fault counts for recovery.json. Counts out of runs, never percentages:
// with 10 seeds a rate would claim precision the sample doesn't have.
const OUTCOMES = ['pass', 'fail', 'not_triggered', 'error'];

export function summarize(runs) {
  const faults = {};
  const total = Object.fromEntries([['runs', 0], ...OUTCOMES.map((o) => [o, 0])]);
  for (const r of runs) {
    const f = (faults[r.fault] ??= {
      runs: 0, ...Object.fromEntries(OUTCOMES.map((o) => [o, 0])),
      partial_turn: {}, duplicates: {}, completed_turns_kept: { n: 0, of: 0 },
    });
    f.runs += 1;
    f[r.outcome] += 1;
    total.runs += 1;
    total[r.outcome] += 1;
    if (r.outcome === 'error') continue;
    f.partial_turn[r.partial_turn] = (f.partial_turn[r.partial_turn] ?? 0) + 1;
    for (const [table, n] of Object.entries(r.duplicates)) f.duplicates[table] = (f.duplicates[table] ?? 0) + n;
    f.completed_turns_kept.n += r.completed_turns_kept.n;
    f.completed_turns_kept.of += r.completed_turns_kept.of;
  }
  return { faults, total };
}
