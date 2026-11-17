// Shape of the privacy-matrix report. The report is meant to be published, so
// it may hold only names and outcome classes: never tokens, ids, emails,
// canary values or response bodies.

const LOOPBACK = new Set(['localhost', '127.0.0.1', '[::1]', '::1']);
const FORBIDDEN = [/CANARY-/, /eyJ[A-Za-z0-9_-]{4,}/, /@example\.test/];

export function assertLocalTarget(url) {
  const parsed = new URL(url);
  if (!LOOPBACK.has(parsed.hostname)) {
    throw new Error('privacy matrix runs against local Supabase only');
  }
  return parsed;
}

// `control: true` marks a positive control: a legitimate request that must be
// let through, proving the deny cells beside it tested something.
export function cell({ surface, target, credential, operation, expected, observed, control = false }) {
  return { surface, target, credential, operation, expected, observed, control, pass: observed === expected };
}

export function buildReport({ commit, cells, startedAt, notes = {} }) {
  const serialized = JSON.stringify({ cells, notes });
  if (FORBIDDEN.some((pattern) => pattern.test(serialized))) {
    throw new Error('report contains forbidden content');
  }
  const controls = cells.filter((c) => c.control);
  const passed = cells.filter((c) => c.pass).length;
  return {
    version: 1,
    target: 'local',
    commit,
    startedAt,
    finishedAt: new Date().toISOString(),
    summary: {
      total: cells.length,
      passed,
      failed: cells.length - passed,
      controls: controls.length,
      controlsPassed: controls.filter((c) => c.pass).length,
    },
    notes,
    cells,
  };
}

export function resultsPath(date, sha) {
  return `eval/results/${date.toISOString().slice(0, 10)}-${sha}/privacy.json`;
}
