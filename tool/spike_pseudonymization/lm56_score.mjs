#!/usr/bin/env node
// LM-56: scores lm56_results/patches.json (the app's swapped-back patches)
// with the spike's metric code (run.mjs on spike/pseudonymization, copied
// below unchanged in behaviour), checks the prompts the handler sent for
// known names, and compares with the spike's raw run and its fixed criteria.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const readJson = (p) => JSON.parse(readFileSync(join(here, p), "utf8"));
const { entities: ENTITIES } = readJson("fixtures/entities.json");
const TRANSCRIPTS = readJson("fixtures/transcripts.json");
const GT = readJson("fixtures/ground_truth.json");
const ROWS = readJson("lm56_results/patches.json");

// The spike's raw run (docs/superpowers/specs/2026-11-07-pseudonymization-spike.md).
const RAW = { entTP: 22, entPred: 33, entTruth: 35, relTP: 18, relPred: 50, relTruth: 25, duplicates: 0 };

// --- from swap.mjs knownNameForms
function knownNameForms(entityList, universe) {
  const forms = new Set();
  for (const e of entityList.filter((x) => x.private)) [e.name, ...e.aliases].forEach((f) => forms.add(f));
  for (const u of Object.values(universe)) {
    if (u.known && !u.public) u.match.forEach((f) => { if (!/^my /i.test(f)) forms.add(f); });
  }
  for (const f of ["marathon", "the Boston Marathon", "Boston Marathon", "Python", "running", "long runs", "training runs"]) forms.delete(f);
  return [...forms];
}
const KNOWN_FORMS = knownNameForms(ENTITIES, GT.universe);
const WORD_NAMES = new Set(ENTITIES.filter((e) => e.isWord).flatMap((e) => [e.name, ...Object.values(GT.universe[e.id]?.match ?? [])]));
const isLatinWord = (s) => /^[\p{Script=Latin}\s'’.-]+$/u.test(s);

// --- from run.mjs leaks()
function leaks(userMessage, transcriptId) {
  let text = userMessage;
  for (const trap of GT.transcripts[transcriptId].wordTraps) text = text.split(trap).join(" ".repeat(trap.length));
  const hits = [];
  for (const f of KNOWN_FORMS) {
    const flags = WORD_NAMES.has(f) ? "u" : "iu";
    const non = isLatinWord(f) ? `(?<![\\p{L}\\p{N}_])${f.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![\\p{L}\\p{N}_])` : f;
    const n = (text.match(new RegExp(non, flags + "g")) ?? []).length;
    if (n) hits.push({ form: f, n });
  }
  return hits;
}

// --- from run.mjs scoring (the patch is already swapped back by the app)
const norm = (s) =>
  String(s).normalize("NFKC").toLowerCase().replace(/_/g, " ").replace(/['’]s\b/g, "").replace(/[^\p{L}\p{N}\s]/gu, "").replace(/\s+/g, " ").trim().replace(/^the /, "");
const RESOLVE = new Map();
for (const [id, u] of Object.entries(GT.universe)) for (const m of [u.name, ...u.match]) RESOLVE.set(norm(m), id);
const resolve = (name) => RESOLVE.get(norm(name)) ?? null;
const EXISTING_IDS = new Set(ENTITIES.map((e) => e.id));
const canon = (id) => ENTITIES.find((e) => e.id === id)?.name;

function scoreCase(transcriptId, out) {
  const gt = GT.transcripts[transcriptId];
  const truthE = new Set(gt.entities);
  const truthR = new Set(gt.relations.map(([a, b]) => [a, b].sort().join("|")));
  const failures = [];
  const ids = out.entities.map((e) => ({ name: e.name, id: resolve(e.name) }));
  const distinct = new Set(ids.filter((x) => x.id).map((x) => x.id));
  const unresolved = ids.filter((x) => !x.id);
  const tpE = [...distinct].filter((id) => truthE.has(id)).length;
  const predE = distinct.size + unresolved.length;
  for (const m of [...truthE].filter((id) => !distinct.has(id))) failures.push(`missed entity ${GT.universe[m].name}`);
  for (const u of unresolved) failures.push(`unmatched entity "${u.name}"`);
  for (const id of distinct) if (!truthE.has(id)) failures.push(`extra entity ${GT.universe[id].name}`);
  let dups = 0;
  const seen = new Map();
  for (const x of ids) {
    if (!x.id) continue;
    seen.set(x.id, (seen.get(x.id) ?? 0) + 1);
    if (EXISTING_IDS.has(x.id) && norm(x.name) !== norm(canon(x.id))) { dups++; failures.push(`duplicate: "${x.name}" is existing ${canon(x.id)}`); }
  }
  for (const [id, n] of seen) if (n > 1) { dups += n - 1; failures.push(`duplicate: ${GT.universe[id].name} returned ${n}x`); }
  const pairs = new Set();
  let unresolvedRel = 0;
  for (const r of out.relations) {
    const a = resolve(r.source), b = resolve(r.target);
    if (!a || !b) { unresolvedRel++; failures.push(`unmatched relation endpoint "${r.source}" -> "${r.target}"`); continue; }
    if (a !== b) pairs.add([a, b].sort().join("|"));
  }
  const tpR = [...pairs].filter((p) => truthR.has(p)).length;
  const predR = pairs.size + unresolvedRel;
  for (const p of truthR) if (!pairs.has(p)) failures.push(`missed relation ${p.split("|").map((i) => GT.universe[i].name).join(" -- ")}`);
  return { tpE, predE, truthE: truthE.size, tpR, predR, truthR: truthR.size, dups, failures };
}

// Stand-in occurrences, whole word, any casing.
function countStandIns(text, standIns) {
  let n = 0;
  for (const s of standIns) {
    const re = new RegExp(`(?<![\\p{L}\\p{N}_])${s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![\\p{L}\\p{N}_])`, "giu");
    n += (text.match(re) ?? []).length;
  }
  return n;
}
const strings = (v) => (typeof v === "string" ? [v] : Array.isArray(v) ? v.flatMap(strings) : v && typeof v === "object" ? Object.values(v).flatMap(strings) : []);

const rows = [];
for (const t of TRANSCRIPTS) {
  const row = ROWS.find((r) => r.transcript === t.id);
  const cacheFile = join(here, "lm56_cache", `${t.id}-lm56.json`);
  const dryFile = join(here, "lm56_cache", `${t.id}-lm56.dry.json`);
  const cached = existsSync(cacheFile)
    ? JSON.parse(readFileSync(cacheFile, "utf8"))
    : existsSync(dryFile)
      ? JSON.parse(readFileSync(dryFile, "utf8"))
      : null;
  const userMessage = cached?.request?.contents?.[0]?.parts?.[0]?.text ?? null;
  const out = { transcript: t.id, ran: Boolean(row?.patch), error: row?.error ?? null };
  out.leaks = userMessage == null ? null : leaks(userMessage, t.id);
  out.leakCount = out.leaks ? out.leaks.reduce((n, h) => n + h.n, 0) : null;
  if (row?.patch) {
    Object.assign(out, scoreCase(t.id, row.patch));
    const rawPatch = (row.rawResponses ?? []).map((b) => { try { return JSON.parse(b).patch; } catch { return null; } }).at(-1);
    const before = countStandIns(strings(rawPatch).join("\n"), row.standIns);
    const after = countStandIns(strings(row.patch).join("\n"), row.standIns);
    out.swapBack = { inModelOutput: before, leftAfterSwapBack: after };
  }
  rows.push(out);
}

const done = rows.filter((r) => r.ran);
const sum = (k) => done.reduce((n, r) => n + (r[k] ?? 0), 0);
const pct = (a, b) => (b ? (100 * a) / b : NaN);
const s = {
  transcriptsRun: done.length,
  entTP: sum("tpE"), entPred: sum("predE"), entTruth: sum("truthE"),
  relTP: sum("tpR"), relPred: sum("predR"), relTruth: sum("truthR"),
  duplicates: sum("dups"),
  leaks: rows.reduce((n, r) => n + (r.leakCount ?? 0), 0),
  standInsInOutput: done.reduce((n, r) => n + r.swapBack.inModelOutput, 0),
  standInsLeft: done.reduce((n, r) => n + r.swapBack.leftAfterSwapBack, 0),
};
s.entPrecision = pct(s.entTP, s.entPred);
s.entRecall = pct(s.entTP, s.entTruth);
s.relPrecision = pct(s.relTP, s.relPred);
s.relRecall = pct(s.relTP, s.relTruth);
const raw = { ...RAW, entPrecision: pct(RAW.entTP, RAW.entPred), entRecall: pct(RAW.entTP, RAW.entTruth), relRecall: pct(RAW.relTP, RAW.relTruth) };
// The spike's criteria, fixed in advance.
const criteria = {
  entRecall: s.entRecall >= raw.entRecall - 5,
  entPrecision: s.entPrecision >= raw.entPrecision - 5,
  relRecall: s.relRecall >= raw.relRecall - 10,
  swapBack100: s.standInsLeft === 0,
  noLeak: s.leaks === 0,
  dupsNoWorse: s.duplicates <= raw.duplicates,
};
const full = done.length === TRANSCRIPTS.length;
const verdict = !full ? "INCONCLUSIVE" : Object.values(criteria).every(Boolean) ? "PASS" : "FAIL";
writeFileSync(join(here, "lm56_results", "score.json"), JSON.stringify({ verdict, criteria, summary: s, raw, rows }, null, 1));

const f = (x) => (Number.isNaN(x) ? "n/a" : x.toFixed(1));
console.log(`verdict: ${verdict}   transcripts run: ${done.length}/${TRANSCRIPTS.length}`);
console.log(`raw (spike)  entP ${f(raw.entPrecision)} (${RAW.entTP}/${RAW.entPred})  entR ${f(raw.entRecall)} (${RAW.entTP}/${RAW.entTruth})  relR ${f(raw.relRecall)} (${RAW.relTP}/${RAW.relTruth})  dups ${RAW.duplicates}`);
console.log(`LM-56 path   entP ${f(s.entPrecision)} (${s.entTP}/${s.entPred})  entR ${f(s.entRecall)} (${s.entTP}/${s.entTruth})  relP ${f(s.relPrecision)} (${s.relTP}/${s.relPred})  relR ${f(s.relRecall)} (${s.relTP}/${s.relTruth})  dups ${s.duplicates}  leaks ${s.leaks}  stand-ins in output ${s.standInsInOutput}, left after swap-back ${s.standInsLeft}`);
console.log(`criteria: ${JSON.stringify(criteria)}`);
for (const r of rows) console.log(`${r.transcript}: ${r.ran ? "ran" : `not run (${r.error})`} leaks=${JSON.stringify(r.leaks)}${r.failures ? ` failures=${JSON.stringify(r.failures)}` : ""}`);
