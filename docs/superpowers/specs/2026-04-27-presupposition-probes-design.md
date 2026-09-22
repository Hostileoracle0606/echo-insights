# Presuppositional Probes — Design Spec

**Date:** 2026-04-27
**Status:** Approved (ready for implementation plan)
**Component:** Voice agent (Gemini Live) + extractor (Gemini 2.5 Flash) + graph state

## Summary

Lumen will, at a soft cadence, weave **presuppositional probes** into its conversational flow — questions whose phrasing implicitly assumes a relation in the graph is true. The user either flows with the presupposition (silent confirmation) or naturally corrects it ("Maya isn't on Atlas, Sam is"). Corrections are detected by the existing per-utterance extractor, which gains a new `supersedes` output. Superseded relations are marked with a timestamp, hidden from the graph view, and excluded from the Obsidian export — but kept in storage as an audit trail.

The feature is delivered through three coordinated changes: a system-prompt extension on the live agent, a new `uncertainRelations` field in the existing `get_graph_summary` payload, and a new optional `supersedes` field in the extractor's output. **No new subsystem, no host-side scheduler, no extra LLM calls.**

## Problem

The extractor produces relations from each utterance under uncertainty. Some are wrong (model misheard, inferred too aggressively across pronouns, fabricated a connection). Today there is no path for the user to correct these — the graph only grows.

We want a way to verify uncertain relations _during the natural conversation_, not as an explicit review step. The verification must be invisible: the user should never feel quizzed or audited.

## Goals

- Probe uncertain relations naturally inside the existing voice dialogue.
- Catch contradictions automatically when the user corrects.
- Hide superseded relations from the graph view and Obsidian export.
- Preserve audit trail (no hard deletes).
- Ship with minimum new state, code, and LLM-call surface area.

## Non-goals

- A separate review/verification UI screen.
- An explicit "is this right?" question style.
- A confidence-decay model (every relation has a number that decays on contradiction). Considered and rejected for v1 in favor of the simpler binary `supersededAt` field.
- Host-side scheduling of probes (deterministic cadence enforcement). The model self-regulates.
- Probe-tracking state (`lastProbeAt`, `probedRelations` set). The model uses its own conversation memory.

## Design decisions (from brainstorming)

| Decision                | Choice                                                       | Rationale                                                                                                  |
| ----------------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| Verification trigger    | Hybrid: uncertainty-weighted with a 5-to-8-turn soft floor   | Pure cadence feels mechanical; pure uncertainty may silence probes for long stretches.                     |
| Probe phrasing          | Socratic presupposition (never "is X right?")                | The user must never feel quizzed; presupposition forces either flow-with or contradict.                    |
| Update on contradiction | Soft supersede via `supersededAt` timestamp                  | Hides from view + export; preserves data; reversible if extractor misfires.                                |
| Vault export            | Superseded relations excluded                                | Vault is the user's clean reference — disputed history doesn't belong there.                               |
| Architecture            | Approach 1 — pure system-prompt influence; no host scheduler | Smallest code change; leans on the live model's natural conversational ability; the model decides cadence. |
| Cadence enforcement     | Soft, prompt-driven; model reads its own recent turns        | No host-side counter to synchronize; one fewer disagreement surface.                                       |
| Candidate signals       | Single-mention OR cross-turn-resolved OR new-pair-connection | Targets the three most plausible extraction-error modes.                                                   |
| Contradiction detection | LLM-judged in the extractor, not host-structural             | Avoids brittle source/target/label string matching; uses semantic judgment.                                |

## Architecture

Three independent pieces, all on existing flows:

```
┌─────────────────────┐
│  Live agent         │  ◄─── system prompt extension teaches presupposition style
│  (Gemini Live)      │  ◄─── get_graph_summary payload gains uncertainRelations[]
└─────────┬───────────┘
          │ speaks
          ▼
┌─────────────────────┐
│  User responds      │
└─────────┬───────────┘
          │ transcript
          ▼
┌─────────────────────┐
│  Extractor          │  ◄─── prompt extension teaches when to emit supersedes
│  (Gemini 2.5 Flash) │  ◄─── output schema gains supersedes: string[]
└─────────┬───────────┘
          │ patch
          ▼
┌─────────────────────┐
│  Host upsert        │  ◄─── for each id in supersedes, set supersededAt = now
│  (routes/index.tsx) │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│  Graph view         │  ◄─── filters out supersededAt != null
│  Obsidian export    │  ◄─── filters out supersededAt != null
└─────────────────────┘
```

The pieces are independently testable. The system-prompt extension can ship without the extractor change (probes happen but contradictions just stack as new relations until cleaned up later). The extractor change can ship without the prompt change (contradictions get caught reactively when the user happens to correct unprompted).

## Data model

### Relation type

In `src/lib/journal-types.ts`:

```ts
export interface Relation {
  id: string;
  source: string;
  target: string;
  label: string;
  metadata: Record<string, string | number | boolean>;
  createdAt: string;
  // NEW: when set, this relation is hidden from graph rendering and from
  // Obsidian export, but kept in storage. Reversible.
  supersededAt?: string;
}
```

### No new persistent state

No top-level fields on `JournalState`. No `probedRelations`, no `lastProbeAt`. The model self-regulates cadence from its own conversation memory.

### Migration

Zero schema migration. Existing relations in localStorage load with `supersededAt: undefined`, which evaluates as "active" in every filter.

### Uncertainty score (computed at read time)

`uncertainRelations` is derived inside `buildGraphSummary` on every call. Each active relation gets a 0–3 integer score from three signals:

| Signal                                                                        | +score | Reasoning                                                    |
| ----------------------------------------------------------------------------- | ------ | ------------------------------------------------------------ |
| Single-mention (relation appears in only one journal entry)                   | +1     | Could be transcription artifact or one-off paraphrase.       |
| Cross-turn resolution (source and target first appeared in different entries) | +1     | Inherently more error-prone than within-sentence extraction. |
| First-time pair (only one active relation between this source+target)         | +1     | Could be model over-connecting.                              |

Top 3 candidates with score ≥ 2 are exposed; lower-score relations aren't worth a probe slot.

## Control flow (per turn)

```
Turn N (user speaks):

1. Gemini Live emits inputTranscription text as the user speaks; the
   final chunk delimits the utterance. (Audio path is direct to Gemini —
   no Deepgram in the loop, despite stale comments in conversation-policy.ts.)
2. Extractor (Gemini 2.5 Flash) runs over the utterance.
   ── Returns: { entities, relations, supersedes? }                  ← supersedes is NEW
3. Host applies the patch:
   - new entities/relations upserted as today
   ── for each id in supersedes: state.relations[id].supersededAt = now  ← NEW
       (silent skip if id is missing or already superseded)
4. Live agent calls get_graph_summary().
   ── Returns same payload as today PLUS uncertainRelations: [...]   ← NEW field
5. Live agent picks next question:
   - Reads uncertainRelations.
   - Reads its own recent turns from its context window.
   - If cadence permits AND a candidate exists → phrases the next question
     to presuppose that candidate's source-label-target.
   - Otherwise → normal question selection per existing prompt.
6. Agent speaks.

Turn N+1 (user responds):
   The user's response either flows with the presupposition (silent
   confirmation — graph unchanged) or contradicts it. If it
   contradicts, the extractor at step 2 of turn N+1 picks up the
   correction and emits a supersedes patch for the original
   relation. The loop closes naturally.
```

### Three properties worth being explicit about

**(a) Confirmation has no acknowledgment.** When the user flows with the probe, nothing happens. The relation isn't marked "verified." This is intentional — if a future utterance contradicts the same relation, the more recent extractor pass should still be able to retract it. Marking-as-verified would be a confidence model, which we deliberately deferred.

**(b) Self-supersede chains can't loop.** When a new relation supersedes an old one, the _new_ relation is what's on the graph going forward. If the model later probes the new relation and the user contradicts again, the new one gets superseded — not the old one. Direction always points forward in time.

**(c) The extractor decides what counts as a contradiction, not the host.** The host doesn't try to detect "Sam works on Atlas" contradicts "Maya works on Atlas" structurally. The extractor sees the existing graph in its prompt context and judges semantically.

## Extractor schema + contradiction detection

### Schema extension in `src/lib/extract-graph.ts`

```ts
const extractGraphFunction = {
  name: "extract_graph",
  description: "...",
  parameters: {
    type: "object",
    properties: {
      entities: {
        /* unchanged */
      },
      relations: {
        /* unchanged */
      },
      // NEW
      supersedes: {
        type: "array",
        description:
          "IDs of existing relations (from EXISTING RELATIONS list, in [brackets]) that the user just contradicted. Empty array if nothing contradicted.",
        items: { type: "string" },
      },
    },
    required: ["entities", "relations"],
  },
};
```

`supersedes` is optional. Most utterances will return an empty array or omit the field.

### Extractor prompt — new SUPERSEDES section

Added to both `WIKI_EXTRACTOR_PROMPT` and `GRANULAR_EXTRACTOR_PROMPT`:

```
SUPERSEDES — when the user contradicts the existing graph:
The user's utterance sometimes corrects, replaces, or denies a relation
already in EXISTING RELATIONS. When that happens, return the contradicted
relation's [bracketed] id in `supersedes`.

Trigger ONLY when the user explicitly:
  - negates a fact ("Maya isn't on Atlas")
  - replaces a fact ("It's not Maya, it's Sam")
  - says something that makes the prior fact mutually exclusive with the
    new one — and the entity referenced is the SAME entity.

Do NOT trigger when:
  - the user adds new info that coexists with the old ("Maya also helps
    Sam" — both can be true)
  - the user is vague or non-committal
  - the relation has the same endpoints but a slightly different label
    (those are fine alongside each other)

Reference relations by their [bracketed] id from the EXISTING RELATIONS
list above. If you can't find an exact id match, do not invent one —
omit the supersede.
```

### `buildUserMessage` extension

The extractor's user message currently shows `EXISTING ENTITIES` and `RECENT CONVERSATION` only. It does **not** currently show existing relations. To support id-based supersedes, we add a new section:

```
EXISTING RELATIONS (each prefixed with [id] — use these IDs in `supersedes`):
- [r_a93f] Maya --works_at--> Stripe
- [r_b7c1] Maya --on--> Project Atlas
- [r_4e2d] Sam --collaborates_with--> Maya
...
```

Cap at top 30 active relations by recency. Adds ~150 input tokens per call. Total per-call input remains well under any rate-limit budget.

### Host application

In the patch-apply path (inside `processGraphUpdate` in `src/routes/index.tsx`):

```ts
for (const id of patch.supersedes ?? []) {
  const relation = state.relations[id];
  if (!relation || relation.supersededAt) continue;
  relation.supersededAt = new Date().toISOString();
}
```

Two-line application. No structural matching, no `slugify` alignment.

### Failure modes

| Mode                                                       | Outcome                                                 | Recovery                                                                                                                                    |
| ---------------------------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| Hallucinated id (model returns id we don't have)           | Silent skip via `if (!relation)`                        | None needed — worst case is a contradiction goes unmarked, not corrupted state. Logged in dev.                                              |
| Missed contradiction (false negative)                      | New relation gets added alongside old; both stay active | Resolved by future utterance or future probe.                                                                                               |
| False positive (model marks a correct relation superseded) | Relation hidden from view + export                      | A later utterance re-mentioning the relation will create a new active relation (existing dedup checks active relations only). Self-healing. |

The prompt's tight definition of "trigger ONLY when..." is the main lever for keeping false positives rare. False positives are the most user-visible failure mode (a relation the user cares about silently disappears).

## System prompt extension (live agent)

Inserted into `GEMINI_LIVE_SYSTEM_INSTRUCTION` in `src/lib/conversation-policy.ts`, after the existing "HOW TO PICK YOUR NEXT QUESTION" block:

```
PRESUPPOSITIONAL PROBES — implicit verification through natural questions:

When `uncertainRelations` in graph_summary is non-empty, the host has
flagged some relations as worth quietly confirming. Each item is
{ source, label, target }, sorted by score (highest = most uncertain).
At most three are returned.

CADENCE — soft 5-to-8-turn rhythm, self-regulated:
  Aim to weave one probe into your next question roughly once every 5–8
  turns. The host does NOT track this for you — gauge it from your own
  recent turns. If you can't recall presupposing an uncertain relation
  in your last ~8 turns, your next question should be a probe. Otherwise
  prefer a normal question from the tier ladder above.

STYLE — never sounds like a clarification:
  Do not ask "is X correct?", "did you say Y?", "I think you mentioned…",
  or anything that names the act of confirming. Instead, phrase a question
  that PRESUPPOSES the relation as true. The user's response either flows
  with it (silent confirmation — graph unchanged) or contradicts it
  (which the extractor catches automatically next turn). Either outcome
  is captured without further work from you. NEVER follow up to check
  whether you got it right.

  Suspect: Maya --on--> Project Atlas
  Bad:  "Did you say Maya was on Atlas?"
  Good: "How's Maya's piece of Atlas been going?"

  Suspect: user --lives_in--> Brooklyn
  Bad:  "Are you still in Brooklyn?"
  Good: "How's Brooklyn been treating you lately?"

  Suspect: Sam --works_with--> Maya
  Bad:  "Is Sam someone Maya works with?"
  Good: "How's Sam been finding it, working alongside Maya?"

The probe must be indistinguishable from a normal warm follow-up. The
user must never feel quizzed or audited.

EXCEPTIONS — defer the probe even if the cadence would fire:
  - The user just shared something tender or emotionally heavy. Reflect
    first; the probe can wait.
  - A tier-1 bridge or tier-2 thin-entity move is more valuable right
    now. You can also PAIR them — "How did Maya end up on Atlas?" both
    bridges Maya↔Atlas AND probes the works_on relation.
  - `uncertainRelations` is empty. Skip this entire section.
```

## `get_graph_summary` extension

In `buildGraphSummary` in `src/routes/index.tsx`, add the `uncertainRelations` field:

```ts
const uncertainRelations = Object.values(s.relations)
  .filter((r) => !r.supersededAt)
  .map((r) => {
    let score = 0;

    // Single-mention: relation appears in exactly one journal entry.
    const mentionCount = s.entries.filter((e) => e.relationIds.includes(r.id)).length;
    if (mentionCount <= 1) score += 1;

    // Cross-turn resolution: source and target first surfaced in
    // different journal entries (more error-prone than within-utterance
    // extraction). Uses entry membership, not entity.firstSeen — those
    // are ms-precision timestamps that almost always differ even for
    // entities introduced in the same utterance.
    const firstEntryOf = (entityId: string) =>
      s.entries.find((e) => e.entityIds.includes(entityId))?.id;
    const sourceEntry = firstEntryOf(r.source);
    const targetEntry = firstEntryOf(r.target);
    if (sourceEntry && targetEntry && sourceEntry !== targetEntry) score += 1;

    // First-time pair: this is the only active relation between
    // these two entities.
    const pairCount = Object.values(s.relations).filter(
      (other) => !other.supersededAt && other.source === r.source && other.target === r.target,
    ).length;
    if (pairCount <= 1) score += 1;

    return {
      source: s.entities[r.source]?.name,
      label: r.label,
      target: s.entities[r.target]?.name,
      score,
    };
  })
  .filter((r) => r.score >= 2 && r.source && r.target)
  .sort((a, b) => b.score - a.score)
  .slice(0, 3);
```

The returned object's `uncertainRelations` is added alongside the existing fields — it does not replace anything.

## Render filters

### Graph view

`src/components/graph-view.tsx` line ~90, the `data` memo's relation filter:

```ts
links: relations
  .filter(
    (r) =>
      !r.supersededAt &&
      entities.find((e) => e.id === r.source) &&
      entities.find((e) => e.id === r.target),
  )
  .map((r) => ({ id: r.id, source: r.source, target: r.target, label: r.label })),
```

### Obsidian export

`src/lib/obsidian-export.ts` line ~203:

```ts
const allRelations = Object.values(state.relations).filter((r) => !r.supersededAt);
```

Both are one-line additions to existing filter chains.

## Testing & validation

No automated tests. The LLM-loop pieces are nondeterministic and the project doesn't have an extractor or live-agent test harness. Validation is manual.

### Manual test plan

1. **Probe phrasing check.** Open a session, mention 4–5 entities with relations, then deliberately stall. After ~5–8 turns the agent should ask a question that presupposes one of the recent relations. If it says "did you say...?" or "is X correct?", the prompt needs more anti-pattern examples.

2. **Contradiction roundtrip.** Mention a relation ("Maya works at Stripe"). Wait a turn. State a contradiction directly ("Actually Maya's at Anthropic, not Stripe"). Within one turn, the older relation should drop from the graph view. Check `state.relations[id].supersededAt` is set in the persisted state. Check the next Obsidian export omits it.

3. **False-positive watch.** Run a 20-minute session. Audit the graph for any relations that disappeared but shouldn't have. Each one is a case to fold into the extractor prompt's "do NOT trigger when..." list.

4. **Cadence sanity.** Eyeball the rate of probes across a 20-minute session. Too frequent → strengthen "defer otherwise" wording. Never → strengthen "your next question MUST be a probe" wording.

### Observability (dev console only)

- `[extractGraph] supersedes patch: [ids]` whenever non-empty.
- `[supersede] no match for id <X>` when the host can't find a referenced relation (hallucination tracking).
- The live `state.relations` object retains supersededAt timestamps, so an audit trail is available via the existing devtools/state inspector.

## Open questions / future work

- **Confidence-decay model.** If false positives turn out to be common under v1's binary supersede, graduate to a numeric confidence per relation (Approach C from the brainstorming). Out of scope for v1.
- **Probe tracking state.** If the model's self-regulation drifts (probes too often or never), add a host-side `lastProbeAt` and `probedRelations` set, exposed via `get_graph_summary`. Out of scope for v1.
- **Stale Deepgram references.** A separate cleanup task is to remove `src/hooks/use-deepgram-recognition.ts` (dead code) and update the stale Deepgram-referencing comments in `src/lib/conversation-policy.ts`. Spawned as a separate session task.
- **`supersededBy` audit pointer.** Considered and dropped from v1 — would have required either structural inference (brittle) or another LLM-decided field (extra complexity). The `supersededAt` timestamp combined with the JSON state history is enough audit trail for now.
