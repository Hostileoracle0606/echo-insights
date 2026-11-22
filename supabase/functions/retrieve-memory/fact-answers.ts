import type { MemoryFact } from "../_shared/memory-fact-contract.ts";
import type { MemoryRoute, MemoryVerdict } from "./memory-query-types.ts";

/**
 * EC-06: exact memory questions answered from stored facts (EC-02, EC-03) by
 * code. There is no model call after the router: the facts were read once,
 * when the user spoke.
 *
 * The router says what kind of question it is; graph selection says which
 * entities; this picks the attribute the question names and computes:
 *   current / previous / as of a date or month   (versions of one value)
 *   the change between the last two versions
 *   whether a planned thing happened             (confirm_event)
 *   totals and differences across items          (calculate)
 * Versions are ordered by when they were true; the same value said twice in
 * a row is one version. Values in different units are never combined.
 *
 * Returns null when no stored fact fits: the caller answers from the user's
 * own words instead.
 */

export type FactEntity = { id: string; name: string };

type Key = { entityId: string; attribute: string; name: string };

const MONTHS = [
  "january", "february", "march", "april", "may", "june",
  "july", "august", "september", "october", "november", "december",
];
const SHORT_MONTHS = MONTHS.map((m) => m.slice(0, 3).replace(/^./, (c) => c.toUpperCase()));

const words = (text: string) => text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
const cap = (text: string) => text.charAt(0).toUpperCase() + text.slice(1);
const when = (f: MemoryFact) => Date.parse(f.eventAt ?? f.statedAt);

function said(f: MemoryFact): string {
  const d = new Date(f.statedAt);
  return `${d.getUTCDate()} ${SHORT_MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
}

function number(n: number): string {
  return Number.isInteger(n) ? String(n) : String(Number(n.toFixed(6)));
}

function value(f: MemoryFact): string {
  const v = f.valueNum !== null ? number(f.valueNum) : f.valueText ?? "";
  return f.unit ? `${v} ${f.unit}` : v;
}

const label = (k: Key) => `${k.name} ${k.attribute.replace(/_/g, " ")}`;

function sameValue(a: MemoryFact, b: MemoryFact): boolean {
  return a.valueNum === b.valueNum &&
    (a.valueText ?? "").toLowerCase() === (b.valueText ?? "").toLowerCase() &&
    (a.unit ?? "").toLowerCase() === (b.unit ?? "").toLowerCase();
}

/** Confirmed versions in the order they were true; a repeat is one version. */
function versions(facts: MemoryFact[]): MemoryFact[] {
  const sorted = facts
    .filter((f) => f.status === "confirmed")
    .sort((a, b) =>
      when(a) - when(b) || Date.parse(a.statedAt) - Date.parse(b.statedAt) || a.id.localeCompare(b.id)
    );
  const out: MemoryFact[] = [];
  for (const f of sorted) {
    if (out.length && sameValue(out[out.length - 1], f)) out[out.length - 1] = f;
    else out.push(f);
  }
  return out;
}

/** Decimal-safe arithmetic in scaled integers. */
function arithmetic(values: number[], subtract: boolean): number {
  const digits = Math.max(...values.map((v) => (String(v).split(".")[1] ?? "").length));
  const scale = 10 ** Math.min(digits, 6);
  const ints = values.map((v) => Math.round(v * scale));
  const result = subtract ? ints[0] - ints[1] : ints.reduce((a, b) => a + b, 0);
  return result / scale;
}

const verdict = (
  status: MemoryVerdict["status"],
  text: string,
  facts: MemoryFact[] = [],
): MemoryVerdict => ({
  status,
  text,
  sourceIds: [...new Set(facts.map((f) => f.sourceEntryId).filter((id): id is string => !!id))],
});

function keysOf(entities: FactEntity[], facts: MemoryFact[]): Key[] {
  const names = new Map(entities.map((e) => [e.id, e.name]));
  const seen = new Map<string, Key>();
  for (const f of facts) {
    const id = `${f.entityId}\u0000${f.attribute}`;
    if (!seen.has(id)) {
      seen.set(id, { entityId: f.entityId, attribute: f.attribute, name: names.get(f.entityId) ?? f.entityId });
    }
  }
  return [...seen.values()];
}

/** Where the entity is named in the question, or -1. */
function position(question: string, k: Key): number {
  const q = ` ${words(question).join(" ")} `;
  const name = ` ${words(k.name).join(" ")} `;
  const at = q.indexOf(name);
  if (at >= 0) return at;
  for (const w of words(k.name)) {
    if (w.length < 3) continue;
    const i = q.indexOf(` ${w} `);
    if (i >= 0) return i;
  }
  return -1;
}

function score(question: string, k: Key, facts: MemoryFact[]): number {
  const q = new Set(words(question));
  const attr = words(k.attribute.replace(/_/g, " ")).filter((w) => q.has(w)).length;
  return attr * 2 + (position(question, k) >= 0 ? 3 : 0) +
    // A tiebreak toward the attribute said about most recently.
    Math.max(...facts.filter((f) => f.entityId === k.entityId && f.attribute === k.attribute)
      .map((f) => Date.parse(f.statedAt))) / 1e15;
}

function best(question: string, keys: Key[], facts: MemoryFact[]): Key {
  return [...keys].sort((a, b) =>
    score(question, b, facts) - score(question, a, facts) ||
    a.entityId.localeCompare(b.entityId) || a.attribute.localeCompare(b.attribute)
  )[0];
}

const factsOf = (k: Key, facts: MemoryFact[]) =>
  facts.filter((f) => f.entityId === k.entityId && f.attribute === k.attribute);

function current(k: Key, facts: MemoryFact[]): MemoryVerdict | null {
  const v = versions(factsOf(k, facts));
  if (v.length) {
    const latest = v[v.length - 1];
    return verdict("supported", `${cap(label(k))}: ${value(latest)} (latest stored, said ${said(latest)}).`, [latest]);
  }
  const plans = factsOf(k, facts).filter((f) => f.status === "proposed")
    .sort((a, b) => Date.parse(a.statedAt) - Date.parse(b.statedAt));
  if (!plans.length) return null;
  const plan = plans[plans.length - 1];
  return verdict("supported", `${cap(label(k))}: ${value(plan)} is planned (said ${said(plan)}), not confirmed.`, [plan]);
}

function previous(k: Key, facts: MemoryFact[]): MemoryVerdict | null {
  const v = versions(factsOf(k, facts));
  if (!v.length) return null;
  if (v.length < 2) {
    return verdict("clarification", "I only have one value stored for that, so there is no earlier one.");
  }
  const before = v[v.length - 2];
  return verdict("supported", `${cap(label(k))} before that: ${value(before)} (said ${said(before)}).`, [before]);
}

function change(k: Key, facts: MemoryFact[]): MemoryVerdict | null {
  const v = versions(factsOf(k, facts));
  if (!v.length) return null;
  if (v.length < 2) {
    return verdict("clarification", "I only have one value stored for that, so there is no earlier one.");
  }
  const [a, b] = v.slice(-2);
  if (a.valueNum === null || b.valueNum === null || (a.unit ?? "") !== (b.unit ?? "")) {
    return verdict("supported", `${cap(label(k))} went from ${value(a)} to ${value(b)}.`, [a, b]);
  }
  const d = arithmetic([b.valueNum, a.valueNum], true);
  const unit = b.unit ? ` ${b.unit}` : "";
  const direction = d === 0 ? "no change" : `${d > 0 ? "up" : "down"} ${number(Math.abs(d))}${unit}`;
  return verdict("supported", `${cap(label(k))} went from ${value(a)} to ${value(b)}: ${direction}.`, [a, b]);
}

function asOf(question: string, k: Key, facts: MemoryFact[]): MemoryVerdict | null {
  const v = versions(factsOf(k, facts));
  if (!v.length) return null;
  const iso = question.match(/\b(\d{4})-(\d{2})-(\d{2})\b/);
  if (iso) {
    const end = Date.parse(`${iso[0]}T23:59:59.999Z`);
    if (!Number.isFinite(end) || new Date(end).toISOString().slice(0, 10) !== iso[0]) {
      return verdict("clarification", "Which date or month do you mean?");
    }
    const then = v.filter((f) => when(f) <= end).pop();
    return then
      ? verdict("supported", `${cap(label(k))} on ${iso[0]}: ${value(then)} (said ${said(then)}).`, [then])
      : verdict("insufficient_evidence", "I don't have a stored value for that time.");
  }
  const month = question.toLowerCase().match(
    /\bin\s+(january|february|march|april|may|june|july|august|september|october|november|december)(?:\s+(\d{4}))?\b/,
  );
  if (!month) return verdict("clarification", "Which date or month do you mean?");
  const m = MONTHS.indexOf(month[1]);
  const inMonth = (f: MemoryFact, year: number) => {
    const d = new Date(when(f));
    return d.getUTCFullYear() === year && d.getUTCMonth() === m;
  };
  let year = month[2] ? Number(month[2]) : null;
  if (year === null) {
    const years = [...new Set(v.filter((f) => new Date(when(f)).getUTCMonth() === m)
      .map((f) => new Date(when(f)).getUTCFullYear()))];
    if (years.length > 1) return verdict("clarification", "Which year do you mean?");
    if (!years.length) return verdict("insufficient_evidence", "I don't have a stored value for that time.");
    year = years[0];
  }
  const then = v.filter((f) => inMonth(f, year!)).pop();
  return then
    ? verdict("supported", `${cap(label(k))} in ${cap(month[1])} ${year}: ${value(then)} (said ${said(then)}).`, [then])
    : verdict("insufficient_evidence", "I don't have a stored value for that time.");
}

/** [question] without its dates, so a year is never read as an amount. */
function withoutDates(question: string): string {
  return question
    .replace(/\b\d{4}-\d{2}-\d{2}\b/g, " ")
    .replace(/\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+\d{4}\b/gi, " ");
}

/** The numbers a question names: "10k" is 10000, "10,000" is 10000. */
function numbersIn(question: string): number[] {
  const out: number[] = [];
  for (const m of question.toLowerCase().matchAll(/(\d[\d,]*(?:\.\d+)?)\s*(k|thousand|m|million)?\b/g)) {
    const base = Number(m[1].replace(/,/g, ""));
    if (!Number.isFinite(base)) continue;
    const scale = m[2] === "k" || m[2] === "thousand" ? 1e3 : m[2] === "m" || m[2] === "million" ? 1e6 : 1;
    out.push(base * scale);
  }
  return out;
}

function happened(question: string, k: Key, facts: MemoryFact[]): MemoryVerdict | null {
  const all = factsOf(k, facts).sort((a, b) =>
    Date.parse(a.statedAt) - Date.parse(b.statedAt) || a.id.localeCompare(b.id)
  );
  if (!all.length) return null;
  let latest = all[all.length - 1];
  // A question that names a value asks about that value, not the latest.
  const named = numbersIn(withoutDates(question));
  if (named.length && latest.valueNum !== null) {
    const matching = all.filter((f) => f.valueNum !== null && named.includes(f.valueNum));
    if (!matching.length) {
      const current = versions(all).pop() ?? latest;
      return verdict(
        "clarification",
        `${cap(label(k))} is ${value(current)} (said ${said(current)}); nothing stored says it was ${named.map(number).join(" or ")}.`,
        [current],
      );
    }
    latest = matching[matching.length - 1];
  }
  if (latest.status === "confirmed") {
    return verdict("supported", `Yes: ${label(k)}: ${value(latest)} (said ${said(latest)}).`, [latest]);
  }
  if (latest.status === "cancelled") {
    return verdict("supported", `${cap(label(k))}: ${value(latest)} was called off (said ${said(latest)}).`, [latest]);
  }
  return verdict(
    "clarification",
    `${cap(label(k))}: ${value(latest)} was planned (said ${said(latest)}), but nothing stored says it happened.`,
    [latest],
  );
}

function calculate(question: string, keys: Key[], facts: MemoryFact[]): MemoryVerdict | null {
  // One key per item the question names, in the question's order.
  const named = new Map<string, Key>();
  for (const k of keys) {
    if (position(question, k) < 0) continue;
    const pick = best(question, keys.filter((x) => x.entityId === k.entityId), facts);
    named.set(pick.entityId, pick);
  }
  const items = [...(named.size >= 2 ? named.values() : keys)]
    .sort((a, b) => position(question, a) - position(question, b));
  const values = items
    .map((k) => ({ k, f: versions(factsOf(k, facts)).pop() }))
    .filter((x): x is { k: Key; f: MemoryFact } => !!x.f && x.f.valueNum !== null);
  if (values.length < 2) {
    return values.length === 1 ? current(values[0].k, facts) : null;
  }
  const units = [...new Set(values.map((x) => (x.f.unit ?? "").toUpperCase()).filter(Boolean))];
  if (units.length > 1) {
    return verdict("clarification", `Those values are in different units (${units.join(", ")}), so I can't combine them.`);
  }
  const unit = units[0] ? ` ${units[0]}` : "";
  const part = (x: { k: Key; f: MemoryFact }, first: boolean) =>
    `${first ? cap(label(x.k)) : label(x.k)} ${value(x.f)}`;
  if (/\b(difference|compared? to|versus|vs\.?|more than|less than|how much more|how much less)\b/i.test(question)) {
    const [a, b] = values;
    const d = arithmetic([a.f.valueNum!, b.f.valueNum!], true);
    return verdict("supported", `${part(a, true)} minus ${part(b, false)} = ${number(d)}${unit}.`, [a.f, b.f]);
  }
  const total = arithmetic(values.map((x) => x.f.valueNum!), false);
  return verdict(
    "supported",
    `${values.map((x, i) => part(x, i === 0)).join(" + ")} = ${number(total)}${unit}.`,
    values.map((x) => x.f),
  );
}

export function answerFromFacts(
  question: string,
  route: MemoryRoute,
  entities: FactEntity[],
  facts: MemoryFact[],
): MemoryVerdict | null {
  if (!facts.length || route.operation === "conversation") return null;
  const keys = keysOf(entities, facts);
  if (!keys.length) return null;
  if (route.operation === "calculate" && route.timeScope !== "compare_versions") {
    return calculate(question, keys, facts);
  }
  const k = best(question, keys, facts);
  if (route.timeScope === "compare_versions") return change(k, facts);
  if (route.operation === "confirm_event") return happened(question, k, facts);
  if (route.timeScope === "previous") return previous(k, facts);
  if (route.timeScope === "as_of") return asOf(question, k, facts);
  return current(k, facts);
}
