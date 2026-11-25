// Baseline report: every metric with its 95% interval and sample size, and the
// share of end-to-end misses each pipeline stage accounts for.
import { bootstrap } from './stats.mjs';

const STAGES = ['extraction', 'admission', 'retrieval', 'answer'];
const LABEL = { extraction: 'Extraction', admission: 'Admission', retrieval: 'Retrieval', answer: 'Answer' };

/** e2e rows -> { stage: { count, share: {value, lo, hi, n, histories} } } over misses, resampling worlds. */
export function attributionShares(rows, { resamples = 2000, seed = 1 } = {}) {
  const misses = rows.filter((r) => !r.correct);
  const out = {};
  for (const stage of STAGES) {
    const share = bootstrap({
      items: misses, groupKey: (r) => r.worldId, resamples, seed,
      metric: (xs) => (xs.length ? xs.filter((r) => r.stage === stage).length / xs.length : null),
    });
    out[stage] = { count: misses.filter((r) => r.stage === stage).length, share };
  }
  return out;
}

const pct = (v) => (v == null ? '–' : `${Math.round(v * 1000) / 10}%`);
const num = (v) => (v == null ? '–' : (Math.round(v * 1000) / 1000).toFixed(3));

export function renderReport(summary) {
  const lines = [];
  lines.push(`# Memory pipeline baseline${summary.smoke ? ' (smoke run)' : ''}`);
  lines.push('');
  lines.push(`**Synthetic benchmark data**, generated in code and worded by Claude; no real user data. Split: ${summary.split}, ${summary.worlds} conversation histories, ${summary.queries} questions. Commit ${summary.commit}, local Supabase stack.`);
  lines.push('');
  const ranked = Object.entries(summary.attribution).sort((a, b) => b[1].count - a[1].count);
  const totalMisses = ranked.reduce((n, [, s]) => n + s.count, 0);
  if (totalMisses) {
    const [top, s] = ranked[0];
    lines.push(`**Largest source of failures:** ${LABEL[top]} accounts for ${pct(s.share.value)} of end-to-end misses (95% CI ${pct(s.share.lo)}–${pct(s.share.hi)}, ${s.count} of ${totalMisses} misses).`);
    lines.push('');
  }
  lines.push('## Where end-to-end misses come from');
  lines.push('');
  lines.push('| Stage | Misses | Share of misses [95% CI] |');
  lines.push('|---|---|---|');
  for (const [stage, s] of ranked) lines.push(`| ${LABEL[stage]} | ${s.count} | ${pct(s.share.value)} [${pct(s.share.lo)}–${pct(s.share.hi)}] |`);
  lines.push('');
  lines.push('## Metrics');
  lines.push('');
  lines.push('| Metric | Value [95% CI] | Sample |');
  lines.push('|---|---|---|');
  for (const [name, m] of Object.entries(summary.metrics)) {
    lines.push(`| ${name} | ${num(m.value)} [${num(m.lo)}–${num(m.hi)}] | n = ${m.n}, histories = ${m.histories} |`);
  }
  lines.push('');
  lines.push('Intervals: 2,000 bootstrap resamples of whole conversation histories (questions about one history move together).');
  if (summary.latency) {
    lines.push('');
    lines.push('## Latency (local stack, not production)');
    lines.push('');
    lines.push('| Stage | P50 ms | P95 ms | n |');
    lines.push('|---|---|---|---|');
    for (const [stage, l] of Object.entries(summary.latency)) lines.push(`| ${stage} | ${l.p50 ?? '–'} | ${l.p95 ?? '–'} | n = ${l.n} |`);
  }
  if (summary.notes?.length) {
    lines.push('');
    lines.push('## Notes');
    lines.push('');
    for (const n of summary.notes) lines.push(`- ${n}`);
  }
  return `${lines.join('\n')}\n`;
}
