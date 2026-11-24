// Claude as the only judge for the memory checks that need reading, not
// string matching: stale facts (in retrieval and in the opening brief),
// decided vs tentative, sequence, and keeping same-named people apart.
// Recall, rank and precision stay deterministic set comparisons in score.mjs.
//
// The judge sees the scenario script (what the user actually said and did),
// the question, and what Lumen retrieved or would say. Background
// distractors are left out: they carry no scenario facts.
import { createHash } from 'node:crypto';

export const JUDGE_MODEL = 'claude-opus-5-5';
export const RUBRIC_VERSION = 2;

export const SYSTEM_PROMPT = `You grade the memory of Lumen, a voice journal that remembers people, places and plans from conversations. You are given a scripted conversation history (ground truth) and what Lumen's memory returned. Judge only from that material.

Definitions:
- A fact is STALE when the user later corrected it, reversed it, or asked Lumen to remove or forget it, and the memory still presents it as currently true. Mentioning an old fact only to say it was wrong or changed ("Dalton, not Dayton"; "had considered leaving but decided to stay") is NOT stale. A removed or forgotten thing appearing at all as live memory IS stale.
- STATUS asks whether the memory conveys only the user's current state for the topic. It is "correct" when the current state (the final decision, or the corrected fact) is stated AND no live statement of an earlier, undecided, or corrected state contradicts it. Any such live contradicting statement makes it "wrong", even if the current state is also present. For an expected state of "tentative", it is correct only when the topic is still presented as undecided.
- ORDER asks whether the memory keeps both the earlier state and the later one, in the right order, so Lumen could say how things changed.
- AMBIGUITY asks whether two different people who share a first name are kept as distinct people, each with their own facts, rather than merged or confused.

Answer "n/a" for any check marked not applicable. Keep each reason to one plain sentence that quotes the deciding words.`;

const verdict = (values) => ({ type: 'string', enum: values });
export const PROBE_SCHEMA = {
  type: 'object',
  properties: {
    stale: verdict(['stale', 'clean', 'n/a']),
    stale_reason: { type: 'string' },
    status: verdict(['correct', 'wrong', 'n/a']),
    status_reason: { type: 'string' },
    order: verdict(['kept', 'lost', 'n/a']),
    order_reason: { type: 'string' },
    ambiguity: verdict(['acknowledged', 'missed', 'n/a']),
    ambiguity_reason: { type: 'string' },
  },
  required: ['stale', 'stale_reason', 'status', 'status_reason', 'order', 'order_reason', 'ambiguity', 'ambiguity_reason'],
  additionalProperties: false,
};
export const BRIEF_SCHEMA = {
  type: 'object',
  properties: { stale: verdict(['stale', 'clean']), reason: { type: 'string' } },
  required: ['stale', 'reason'],
  additionalProperties: false,
};

/** The scenario as ground truth: every turn in order, and the user's memory actions. */
export function scriptOf(scenario) {
  const lines = [];
  scenario.sessions.forEach((session, i) => {
    lines.push(`Session ${i + 1}:`);
    for (const turn of session.turns) lines.push(`  User: ${turn}`);
    for (const a of scenario.actions ?? []) {
      if (a.after_session !== i + 1) continue;
      if (a.kind === 'correct') lines.push(`  [User edited the memory of "${a.name}" to read: "${a.description}"]`);
      else if (a.kind === 'remove') lines.push(`  [User removed "${a.name}" from Lumen's memory]`);
      else if (a.kind === 'forget') lines.push(`  [User asked Lumen to forget "${a.name}"]`);
    }
  });
  return lines.join('\n');
}

/** Which probe checks apply; mirrors score.mjs so judged and rule counts share denominators. */
export function applicable(probe, rule) {
  return {
    stale: rule.stale !== null,
    status: Boolean(probe.expect_status),
    order: Boolean(probe.expect_order?.length),
    ambiguity: Boolean(probe.expect_ambiguity),
  };
}

export function probeInput(scenario, probe, result, rule) {
  const memory = (result.retrieved ?? [])
    .map((item, i) => ({ rank: i + 1, ...item }))
    .filter((item) => !item.background)
    .map((item) => `#${item.rank} ${item.name}\n${[item.text, item.history].filter(Boolean).join('\n')}`)
    .join('\n\n');
  const checks = applicable(probe, rule);
  const notes = [];
  if (checks.stale) {
    const outdated = [...(probe.expect_not_retrieved ?? []), ...(probe.stale_text ?? [])];
    notes.push(`stale: applicable. No longer current per the script: ${outdated.join('; ')}`);
  } else notes.push('stale: not applicable');
  notes.push(checks.status ? `status: applicable. The current state should be "${probe.expect_status}"` : 'status: not applicable');
  notes.push(checks.order ? `order: applicable. Earlier to later: ${probe.expect_order.join(' -> ')}` : 'order: not applicable');
  notes.push(checks.ambiguity ? `ambiguity: applicable. Shared name: "${probe.ambiguity_token}"` : 'ambiguity: not applicable');
  return {
    checks,
    text: `<script>\n${scriptOf(scenario)}\n</script>\n\n<question>${probe.ask}</question>\n\n<retrieved_memory>\n${memory || '(nothing from this conversation)'}\n</retrieved_memory>\n\n<checks>\n${notes.join('\n')}\n</checks>`,
  };
}

export function briefInput(scenario, briefText) {
  const outdated = new Set();
  for (const p of scenario.probes) for (const t of [...(p.expect_not_retrieved ?? []), ...(p.stale_text ?? [])]) outdated.add(t);
  return `<script>\n${scriptOf(scenario)}\n</script>\n\nThis is what Lumen prepared to say when the user opens the next conversation:\n<opening_brief>\n${briefText}\n</opening_brief>\n\nNo longer current per the script: ${[...outdated].join('; ')}\n\nDoes the opening brief present any of those, or anything else the script corrected, reversed, removed or forgot, as currently true?`;
}

export function cacheKey(kind, text) {
  return createHash('sha256').update(`${JUDGE_MODEL}\n${RUBRIC_VERSION}\n${SYSTEM_PROMPT}\n${kind}\n${text}`).digest('hex');
}

export class JudgeUnavailable extends Error {
  constructor(message) { super(message); this.name = 'JudgeUnavailable'; }
}

/** One structured-output call. `client` is an Anthropic SDK client (or a test double with the same shape). */
export async function ask(client, text, schema) {
  const response = await client.beta.messages.create({
    model: JUDGE_MODEL,
    max_tokens: 16000,
    betas: ['server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    output_config: { effort: 'high', format: { type: 'json_schema', schema } },
    system: SYSTEM_PROMPT,
    messages: [{ role: 'user', content: text }],
  });
  if (response.stop_reason === 'refusal') throw new JudgeUnavailable(`judge refused (${response.stop_details?.category ?? 'no category'})`);
  if (response.stop_reason === 'max_tokens') throw new JudgeUnavailable('judge hit max_tokens');
  const block = response.content.find((b) => b.type === 'text');
  if (!block) throw new JudgeUnavailable('judge returned no text');
  return { verdict: JSON.parse(block.text), model: response.model, usage: response.usage };
}

/** Forces "n/a" on checks the probe doesn't make, so a judge can't add or drop a denominator. */
export function normalizeProbeVerdict(verdict, checks) {
  const out = { ...verdict };
  for (const key of ['stale', 'status', 'order', 'ambiguity']) {
    if (!checks[key]) out[key] = 'n/a';
    else if (out[key] === 'n/a') out[key] = 'unjudged';
  }
  return out;
}

/** Replaces the rule-based semantic fields of a scoreProbe() row with the judge's. */
export function applyVerdict(row, verdict, briefStale) {
  const staleIn = [];
  if (verdict.stale === 'stale') staleIn.push('retrieval');
  if (row.stale !== null && briefStale === true) staleIn.push('brief');
  return {
    ...row,
    stale: row.stale === null ? null : staleIn.length > 0,
    staleIn,
    status: verdict.status === 'unjudged' ? 'wrong' : verdict.status,
    order: verdict.order === 'unjudged' ? 'lost' : verdict.order,
    ambiguity: verdict.ambiguity === 'unjudged' ? 'missed' : verdict.ambiguity,
  };
}
