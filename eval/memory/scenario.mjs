// Memory-quality scenarios: scripted sessions of user turns, user actions
// (correct, remove, forget) between sessions, and labeled probes. JSON, so no
// new dependency. Every text is synthetic; every name is invented.
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const CATEGORIES = Object.freeze(['continuity', 'correction', 'deletion', 'changing_facts']);
export const ACTION_KINDS = Object.freeze(['correct', 'remove', 'forget']);
const STATUSES = new Set(['tentative', 'decided', 'superseded']);

const strings = (v) => Array.isArray(v) && v.every((x) => typeof x === 'string' && x.trim());

function check(s) {
  if (typeof s?.id !== 'string' || !/^[a-z0-9-]+$/.test(s.id)) return 'id';
  if (!CATEGORIES.includes(s.category)) return 'category';
  if (!Array.isArray(s.sessions) || s.sessions.length === 0) return 'sessions';
  for (const [i, session] of s.sessions.entries()) {
    if (!strings(session?.turns) || session.turns.length === 0) return `sessions[${i}].turns`;
  }
  for (const [i, a] of (s.actions ?? []).entries()) {
    if (!ACTION_KINDS.includes(a?.kind)) return `actions[${i}].kind`;
    if (!Number.isInteger(a.after_session) || a.after_session < 1 || a.after_session > s.sessions.length) {
      return `actions[${i}].after_session`;
    }
    if (typeof a.name !== 'string' || !a.name.trim()) return `actions[${i}].name`;
    if (a.kind === 'correct' && (typeof a.description !== 'string' || !a.description.trim())) {
      return `actions[${i}].description`;
    }
  }
  if (!Array.isArray(s.probes) || s.probes.length === 0) return 'probes';
  for (const [i, p] of s.probes.entries()) {
    const at = `probes[${i}]`;
    if (typeof p?.ask !== 'string' || !p.ask.trim()) return `${at}.ask`;
    for (const key of ['expect_retrieved', 'expect_not_retrieved', 'decided_markers', 'tentative_markers', 'expect_order', 'stale_text', 'distractors', 'related']) {
      if (p[key] !== undefined && !(Array.isArray(p[key]) && (p[key].length === 0 || strings(p[key])))) return `${at}.${key}`;
    }
    if (!p.expect_retrieved?.length && !p.expect_not_retrieved?.length) return `${at}.expect_retrieved`;
    if (p.expect_status !== undefined && !STATUSES.has(p.expect_status)) return `${at}.expect_status`;
    if (p.expect_status && !p.decided_markers?.length && !p.tentative_markers?.length) return `${at}.decided_markers`;
    if (p.expect_ambiguity !== undefined && typeof p.expect_ambiguity !== 'boolean') return `${at}.expect_ambiguity`;
    if (p.expect_ambiguity && (typeof p.ambiguity_token !== 'string' || !p.ambiguity_token.trim())) return `${at}.ambiguity_token`;
  }
  return null;
}

export function loadScenarios(dir) {
  const files = readdirSync(dir).filter((f) => f.endsWith('.json')).sort();
  return files.map((file) => {
    let scenario;
    try {
      scenario = JSON.parse(readFileSync(join(dir, file), 'utf8'));
    } catch (error) {
      throw new Error(`${file}: not valid JSON (${error.message})`);
    }
    const bad = check(scenario);
    if (bad) throw new Error(`${file}: invalid field ${bad}`);
    return { actions: [], ...scenario };
  });
}

// Round-robin over CATEGORIES, keeping each category's own order: a day's
// quota that runs out partway still covers every category.
export function interleaveByCategory(scenarios) {
  const queues = CATEGORIES.map((c) => scenarios.filter((s) => s.category === c));
  const out = [];
  while (queues.some((q) => q.length)) for (const q of queues) if (q.length) out.push(q.shift());
  return out;
}
