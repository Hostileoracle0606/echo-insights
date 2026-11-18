// Per-stage p50/p95 ("where the person waits") from captured timing runs.
//
//   npm run eval:timing:summary -- eval/results/<date>-<sha>/timing
//
// Reads <group>-<n>.jsonl run files and meta.json ({group: {device, mode,
// network, history}}), writes timing.json beside them. Groups never mix
// devices, build modes or network profiles.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseRun } from './parse.mjs';

/** Nearest-rank percentile; null for no values. */
export function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = Math.max(1, Math.ceil((p / 100) * sorted.length));
  return sorted[rank - 1];
}

const MERGE_KEYS = ['device', 'mode', 'network'];

/** Joins runs that share device, build mode and network; numbers each run. */
export function combine(inputs) {
  const first = inputs[0]?.meta ?? {};
  for (const { meta } of inputs) {
    for (const key of MERGE_KEYS) {
      if (meta[key] !== first[key]) {
        throw new Error(`refusing to merge runs with different ${key}: ${first[key]} vs ${meta[key]}`);
      }
    }
  }
  return {
    meta: first,
    marks: inputs.flatMap(({ marks }, i) => marks.map((mark) => ({ ...mark, run: i + 1 }))),
  };
}

export function summarize(marks, meta) {
  const byStage = new Map();
  const stage = (name) => {
    if (!byStage.has(name)) byStage.set(name, { values: [], incomplete: 0, failed: 0 });
    return byStage.get(name);
  };
  const open = new Map(); // `${run}/${stage}` → begun and not yet ended
  let overlaps = 0;
  let overlapOf = 0;

  for (const mark of marks) {
    const s = stage(mark.stage);
    if (typeof mark.overlap === 'boolean') {
      overlapOf += 1;
      if (mark.overlap) overlaps += 1;
    }
    const key = `${mark.run ?? 0}/${mark.stage}`;
    if (mark.phase === 'begin') {
      if (open.get(key)) s.incomplete += 1; // re-begun: the earlier one never ended
      open.set(key, true);
      continue;
    }
    if (mark.phase === 'end') {
      const begun = open.get(key);
      open.delete(key);
      if (mark.incomplete || !begun) {
        s.incomplete += 1;
        continue;
      }
    }
    if (mark.ok === false) {
      s.failed += 1;
      continue;
    }
    s.values.push(mark.phase === 'mark' ? mark.t_ms : mark.dur_ms);
  }
  for (const [key, begun] of open) {
    if (begun) stage(key.slice(key.indexOf('/') + 1)).incomplete += 1;
  }

  const stages = {};
  for (const [name, s] of byStage) {
    stages[name] = {
      n: s.values.length, p50: percentile(s.values, 50), p95: percentile(s.values, 95),
      incomplete: s.incomplete, failed: s.failed,
    };
  }
  return { stages, overlapRate: [overlaps, overlapOf], meta };
}

/** Summarizes every group of run files in [dir] using its meta.json. */
export function summarizeDir(dir) {
  const metaByGroup = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
  const files = readdirSync(dir).filter((f) => f.endsWith('.jsonl')).sort();
  const groups = new Map();
  for (const file of files) {
    const group = file.replace(/-\d+\.jsonl$/, '');
    if (!groups.has(group)) groups.set(group, []);
    groups.get(group).push(file);
  }
  const out = { groups: {} };
  for (const [group, groupFiles] of groups) {
    const meta = metaByGroup[group];
    if (!meta?.device || !meta?.mode) throw new Error(`no meta (device, mode) for group ${group}`);
    let rejected = 0;
    const runs = groupFiles.map((file) => {
      const parsed = parseRun(readFileSync(join(dir, file), 'utf8'), { allowDebug: meta.mode === 'debug' });
      rejected += parsed.rejected;
      for (const mark of parsed.marks) {
        if (mark.mode !== meta.mode) throw new Error(`${file}: mode ${mark.mode} but meta says ${meta.mode}`);
      }
      return { marks: parsed.marks, meta };
    });
    const { marks } = combine(runs);
    out.groups[group] = { ...summarize(marks, meta), runs: groupFiles.length, rejected };
  }
  return out;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const dir = resolve(process.argv[2] ?? '');
  const out = { generatedAt: new Date().toISOString(), ...summarizeDir(dir) };
  writeFileSync(join(dir, 'timing.json'), `${JSON.stringify(out, null, 2)}\n`);
  for (const [group, s] of Object.entries(out.groups)) {
    for (const [stage, v] of Object.entries(s.stages)) {
      console.log(`${group.padEnd(20)} ${stage.padEnd(30)} n=${String(v.n).padStart(3)} p50=${v.p50} p95=${v.p95} incomplete=${v.incomplete} failed=${v.failed}`);
    }
  }
}
