// Bootstrap confidence intervals that resample whole conversation histories.
// Questions about one history share its extraction and graph, so they are not
// independent; resampling them one by one would give falsely narrow intervals.

function rng(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

function groups(items, groupKey) {
  const map = new Map();
  for (const x of items) {
    const k = groupKey(x);
    if (!map.has(k)) map.set(k, []);
    map.get(k).push(x);
  }
  return [...map.values()];
}

function resampleGroups(gs, rand) {
  const out = [];
  for (let i = 0; i < gs.length; i += 1) out.push(...gs[Math.floor(rand() * gs.length)]);
  return out;
}

const quantile = (sorted, q) => sorted[Math.min(sorted.length - 1, Math.max(0, Math.floor(q * sorted.length)))];

/** metric(items) -> number | null. Returns { value, lo, hi, n, histories } (95% percentile interval). */
export function bootstrap({ items, groupKey, metric, resamples = 2000, seed = 1 }) {
  const gs = groups(items, groupKey);
  const value = metric(items);
  const rand = rng(seed);
  const draws = [];
  for (let i = 0; i < resamples; i += 1) {
    const v = metric(resampleGroups(gs, rand));
    if (v != null && Number.isFinite(v)) draws.push(v);
  }
  draws.sort((a, b) => a - b);
  return { value, lo: draws.length ? quantile(draws, 0.025) : null, hi: draws.length ? quantile(draws, 0.975) : null, n: items.length, histories: gs.length };
}

/** Same resamples for a and b, so the interval is on the paired difference a - b. */
export function pairedBootstrap({ items, groupKey, a, b, resamples = 2000, seed = 1 }) {
  const gs = groups(items, groupKey);
  const diff = a(items) - b(items);
  const rand = rng(seed);
  const draws = [];
  for (let i = 0; i < resamples; i += 1) {
    const sample = resampleGroups(gs, rand);
    const d = a(sample) - b(sample);
    if (Number.isFinite(d)) draws.push(d);
  }
  draws.sort((x, y) => x - y);
  return { diff, lo: quantile(draws, 0.025), hi: quantile(draws, 0.975), n: items.length, histories: gs.length };
}
