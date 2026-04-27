# Presuppositional Probes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify uncertain graph relations through implicit Socratic probes the live agent weaves into its natural questions; corrections are caught by the extractor and applied as soft-supersede timestamps that hide superseded relations from the graph view and Obsidian export.

**Architecture:** Three coordinated changes on existing flows. (1) Relation gains an optional `supersededAt` ISO timestamp. (2) The extractor's output schema gains an optional `supersedes: string[]` field carrying ids of relations the user just contradicted; ids come from a new `EXISTING RELATIONS` section in the extractor's user message. (3) `get_graph_summary` gains an `uncertainRelations` field exposing the top-3 highest-uncertainty active relations to the live agent, which is taught (via system prompt) to phrase Socratic presupposition questions over them at a soft 5–8 turn cadence. No host scheduler, no probe-tracking state, no extra LLM calls.

**Tech Stack:** TypeScript (strict), React, Zod, Vite, Gemini 2.5 Flash (extractor REST), Gemini Live (voice), TanStack Router. The project has no automated test harness for the extractor or live agent — validation is type-check + manual smoke testing per the spec.

**Companion spec:** [`docs/superpowers/specs/2026-04-27-presupposition-probes-design.md`](../specs/2026-04-27-presupposition-probes-design.md)

---

## File Map

| File | Change |
|---|---|
| `src/lib/journal-types.ts` | Add `supersededAt?: string` to `Relation`. |
| `src/components/graph-view.tsx` | Filter `!r.supersededAt` from rendered links. |
| `src/lib/obsidian-export.ts` | Filter `!r.supersededAt` from `allRelations`. |
| `src/routes/index.tsx` | (a) `buildExtractionContext` includes relation `id`, sorts by recency, excludes superseded, caps at 30. (b) `processGraphUpdate` propagates `supersedes` through the payload. (c) `buildGraphSummary` adds `uncertainRelations`. (d) Tool description mentions `uncertainRelations`. |
| `src/lib/extract-graph.ts` | (a) `extractGraphFunction.parameters` adds `supersedes`. (b) `graphPatchSchema` adds `supersedes`. (c) `buildUserMessage` renders `EXISTING RELATIONS [id]` block. (d) Both extractor prompts gain a `SUPERSEDES — when the user contradicts the existing graph` section. (e) `ExtractGraphResult` + `patchToResult` + `filterNoise` thread `supersedes` through. (f) `GraphRelation` interface optionally includes `id`. |
| `src/lib/journal-store.ts` | (a) `ExtractedPayload` adds `supersedes?: string[]`. (b) `mergeExtraction` applies supersedes and un-supersedes a relation if it's re-asserted in the same patch. |
| `src/lib/conversation-policy.ts` | Append `PRESUPPOSITIONAL PROBES` block to `GEMINI_LIVE_SYSTEM_INSTRUCTION`. |

## Verification commands

The project has no `typecheck` script in `package.json`. Use:

```bash
npx tsc --noEmit
```

after each task to confirm types still align. Vite dev server (`npm run dev`) is used for manual smoke testing in Task 12.

**Note about commits:** the working tree currently has many unrelated uncommitted changes from prior work. Stage **only** the files listed in each task — never use `git add -A` or `git add .`.

---

## Task 1: Add `supersededAt` field to the Relation type

**Files:**
- Modify: `src/lib/journal-types.ts:31-38`

This is the foundational change — every subsequent task depends on the field existing. Optional, no migration needed: existing relations in localStorage load with `supersededAt: undefined`, which falsy-evaluates as "active" everywhere we filter.

- [ ] **Step 1: Add the field**

In `src/lib/journal-types.ts`, replace the `Relation` interface (lines 31-38) with:

```ts
export interface Relation {
  id: string;
  source: string;      // entity id
  target: string;      // entity id
  label: string;       // e.g. "works_with", "lives_in", "feels"
  metadata: Record<string, string | number | boolean>;
  createdAt: string;
  /**
   * When set, the relation has been soft-superseded — typically because
   * the user contradicted it in conversation and the extractor flagged
   * it via `supersedes`. Hidden from the graph view and the Obsidian
   * export; preserved in storage as an audit trail. Reversible: if the
   * user re-asserts the same source/label/target, the merge step clears
   * the timestamp.
   */
  supersededAt?: string;
}
```

- [ ] **Step 2: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS, no errors. (No callers consume the new field yet, so adding an optional property is safe.)

- [ ] **Step 3: Commit**

```bash
git add src/lib/journal-types.ts
git commit -m "$(cat <<'EOF'
Add supersededAt to Relation type

Optional ISO timestamp that marks a relation as soft-superseded.
Foundation for the presuppositional-probe feature: subsequent commits
add filters in graph view + Obsidian export, then the extractor and
live-agent wiring that drives the timestamp.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Hide superseded relations from the graph view

**Files:**
- Modify: `src/components/graph-view.tsx:89-93`

Safe to ship before any superseder exists — no relation has `supersededAt` set yet, so this filter is a no-op until Task 8 lands. Shipping it early means the rendering side is in place by the time supersedes start landing.

- [ ] **Step 1: Add the filter to the data memo**

In `src/components/graph-view.tsx`, locate the `data` `useMemo` block (lines 80-96). Replace its `links` filter (lines 89-93) so superseded relations are excluded:

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

- [ ] **Step 2: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/components/graph-view.tsx
git commit -m "$(cat <<'EOF'
Hide superseded relations from the graph view

One-line filter on the data memo's links chain so soft-superseded
relations never make it into the force-graph render. No effect yet —
nothing sets supersededAt — but lands the rendering side ahead of the
extractor wiring.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Hide superseded relations from the Obsidian export

**Files:**
- Modify: `src/lib/obsidian-export.ts:203`

The Obsidian vault is the user's clean reference. Disputed history doesn't belong there. One-liner filter on the source array used everywhere downstream in the export.

- [ ] **Step 1: Filter at the source**

In `src/lib/obsidian-export.ts`, locate line 203 (`const allRelations = ...`). Replace the line with:

```ts
  const allRelations = Object.values(state.relations).filter((r) => !r.supersededAt);
```

The `outgoing` / `incoming` filters at lines 235-236 already operate on `allRelations`, so they inherit the filter automatically.

- [ ] **Step 2: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/lib/obsidian-export.ts
git commit -m "$(cat <<'EOF'
Exclude superseded relations from Obsidian export

The vault is the user's clean reference; soft-superseded relations
(set by the upcoming presupposition-probe pipeline) shouldn't appear
in exported pages. Filter at the source array so downstream outgoing/
incoming uses inherit it.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Pass relation `id` and recency-cap to the extractor context

**Files:**
- Modify: `src/lib/extract-graph.ts:99-104` (the `GraphRelation` interface)
- Modify: `src/routes/index.tsx:271-278` (the `existingRelations` builder)

The extractor needs to reference relations by id when emitting `supersedes`. Currently `buildExtractionContext` strips the id. We add `id?: string` to the `GraphRelation` shape (optional so external callers stay compatible) and have the host emit it. We also tighten the slice to top 30 active, sorted by recency, matching the spec.

- [ ] **Step 1: Allow `id` on GraphRelation**

In `src/lib/extract-graph.ts`, replace the `GraphRelation` interface (lines 99-104) with:

```ts
interface GraphRelation {
  /** Optional stable id. Required for `supersedes` to be referenceable; absent for legacy callers. */
  id?: string;
  source: string;
  target: string;
  label: string;
  metadata?: Record<string, unknown>;
}
```

- [ ] **Step 2: Build existingRelations with id, recency-sorted, capped at 30, active-only**

In `src/routes/index.tsx`, replace the `existingRelations` block inside `buildExtractionContext` (lines 271-278) with:

```ts
    existingRelations: Object.values(state.relations)
      .filter((relation) => !relation.supersededAt)
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .slice(0, 30)
      .map((relation) => ({
        id: relation.id,
        source: byId[relation.source]?.name ?? relation.source,
        target: byId[relation.target]?.name ?? relation.target,
        label: relation.label,
        metadata: relation.metadata,
      })),
```

The cap drops from 50→30 deliberately: 30 ids fit comfortably in the prompt's token budget, the 30 most recent are the most likely to be referenced in a contradiction, and we save ~150 tokens per call vs the prior cap.

- [ ] **Step 3: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/lib/extract-graph.ts src/routes/index.tsx
git commit -m "$(cat <<'EOF'
Thread relation ids through to the extractor context

GraphRelation gains an optional id. buildExtractionContext now emits
ids alongside source/target/label, filters out soft-superseded
relations, sorts by createdAt desc, and caps at 30. Sets up the
extractor's EXISTING RELATIONS section for supersede-by-id.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add `supersedes` to the extractor schema and result

**Files:**
- Modify: `src/lib/extract-graph.ts:232-258` (`ExtractGraphResult`, `emptyResult`)
- Modify: `src/lib/extract-graph.ts:423-426` (`graphPatchSchema`)
- Modify: `src/lib/extract-graph.ts:450-473` (`filterNoise`)
- Modify: `src/lib/extract-graph.ts:475-490` (`patchToResult`)
- Modify: `src/lib/extract-graph.ts:497-541` (`extractGraphFunction`)

Wire the optional `supersedes: string[]` through every layer between the Gemini function-call response and the host's `ExtractGraphResult`. This task only adds the field — Task 7 teaches the model when to emit it, and Task 8 applies it.

- [ ] **Step 1: Extend `ExtractGraphResult`**

In `src/lib/extract-graph.ts`, replace the `ExtractGraphResult` interface (lines 232-252) with:

```ts
export interface ExtractGraphResult {
  entities: Array<{
    name: string;
    type: string;
    description?: string;
    metadata?: Record<string, string>;
    /** Wiki-mode: per-entity question backlog. Empty in granular mode. */
    questions?: string[];
  }>;
  relations: Array<{
    source: string;
    target: string;
    label: string;
    metadata?: Record<string, string>;
  }>;
  /**
   * Ids of EXISTING RELATIONS the user just contradicted. The host clears
   * the corresponding relations by setting supersededAt = now. Empty (or
   * omitted) on most turns. Ids that don't match anything in state are
   * silently skipped — see processGraphUpdate / mergeExtraction.
   */
  supersedes?: string[];
  followUp: {
    question: string;
    reason: string;
    targetEntityNames: string[];
  };
}
```

- [ ] **Step 2: Update `emptyResult` to omit supersedes**

In the same file, replace `emptyResult` (lines 254-258) with:

```ts
const emptyResult = (): ExtractGraphResult => ({
  entities: [],
  relations: [],
  supersedes: [],
  followUp: { question: "", reason: "", targetEntityNames: [] },
});
```

- [ ] **Step 3: Extend `graphPatchSchema`**

Replace `graphPatchSchema` (lines 423-426) with:

```ts
const graphPatchSchema = z.object({
  entities: z.array(entityPatchSchema),
  relations: z.array(relationPatchSchema),
  supersedes: z.array(z.string().min(1)).optional(),
});
```

- [ ] **Step 4: Pass supersedes through `filterNoise`**

In `filterNoise` (lines 450-473), the function returns `{ entities, relations }`. Update its return type and propagate `supersedes` unchanged (ids are not entity names, so the noise filter never applies). Replace the function with:

```ts
const filterNoise = (patch: GraphPatch): GraphPatch => {
  const kept = patch.entities.filter((e) => {
    const key = normalizeName(e.name);
    if (!key) return false;
    if (NOISE_NAMES.has(key)) return false;
    // Single-character names are almost always pronoun/transcription noise.
    if (key.length < 2) return false;
    return true;
  });
  const keptKeys = new Set(kept.map((e) => normalizeName(e.name)));
  // Drop relations whose endpoints don't survive the entity filter — but
  // keep relations whose endpoints reference EXISTING ENTITIES (not in this
  // patch). We can't validate those here, so trust the model on cross-patch
  // edges and only drop edges that point at noise we just removed.
  const droppedKeys = new Set(
    patch.entities
      .map((e) => normalizeName(e.name))
      .filter((k) => !keptKeys.has(k)),
  );
  const relations = patch.relations.filter(
    (r) => !droppedKeys.has(normalizeName(r.source)) && !droppedKeys.has(normalizeName(r.target)),
  );
  // supersedes carries opaque ids, not entity names — pass through.
  return { entities: kept, relations, supersedes: patch.supersedes };
};
```

- [ ] **Step 5: Pass supersedes through `patchToResult`**

Replace `patchToResult` (lines 475-490) with:

```ts
const patchToResult = (patch: GraphPatch): ExtractGraphResult => ({
  entities: patch.entities.map((entity) => ({
    name: entity.name,
    type: entity.type,
    description: entity.description,
    metadata: entity.metadata,
    questions: entity.questions,
  })),
  relations: patch.relations.map((relation) => ({
    source: relation.source,
    target: relation.target,
    label: relation.label,
    metadata: relation.metadata,
  })),
  supersedes: patch.supersedes ?? [],
  followUp: { question: "", reason: "", targetEntityNames: [] },
});
```

- [ ] **Step 6: Add `supersedes` to the function declaration sent to Gemini**

In `extractGraphFunction.parameters.properties` (lines 502-538), add a `supersedes` property after `relations`. Replace the entire `extractGraphFunction` (lines 497-541) with:

```ts
const extractGraphFunction = {
  name: "extract_graph",
  description: "Return entities and relations mentioned in NEW UTTERANCE.",
  parameters: {
    type: "object",
    properties: {
      entities: {
        type: "array",
        items: {
          type: "object",
          properties: {
            name: { type: "string" },
            type: {
              type: "string",
              enum: ["person", "place", "organization", "project", "event", "object", "other"],
            },
            description: { type: "string" },
            metadata: { type: "object" },
            questions: {
              type: "array",
              items: { type: "string" },
              description:
                "Wiki-mode only: 2-4 follow-up questions Lumen could ask about this entity. Omit in granular mode.",
            },
          },
          required: ["name", "type"],
        },
      },
      relations: {
        type: "array",
        items: {
          type: "object",
          properties: {
            source: { type: "string" },
            target: { type: "string" },
            label: { type: "string" },
            metadata: { type: "object" },
          },
          required: ["source", "target", "label"],
        },
      },
      supersedes: {
        type: "array",
        items: { type: "string" },
        description:
          "Ids of relations from EXISTING RELATIONS (the [bracketed] prefix) that the user just contradicted. Empty array if nothing contradicted. Use the EXACT id from the brackets — never invent one.",
      },
    },
    required: ["entities", "relations"],
  },
};
```

- [ ] **Step 7: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/lib/extract-graph.ts
git commit -m "$(cat <<'EOF'
Add supersedes to the extractor schema

Wire an optional supersedes: string[] through every layer between
the Gemini function-call response and ExtractGraphResult: function
declaration, zod schema, filterNoise, patchToResult, emptyResult.
The model isn't taught when to emit yet — that lands in the prompt
update — and the host doesn't apply yet either. Wiring only.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Render `EXISTING RELATIONS [id]` block in the extractor user message

**Files:**
- Modify: `src/lib/extract-graph.ts:310-313` (the `formatRelation` helper)
- Modify: `src/lib/extract-graph.ts:388-401` (the `buildUserMessage` function)

The model can only reference an id it sees. We render the host's pre-prepared `existingRelations` (already in the body, already including ids since Task 4) into a section formatted like the spec mockup.

- [ ] **Step 1: Update `formatRelation` to prefix the id when present**

Replace `formatRelation` (lines 310-313) with:

```ts
const formatRelation = (relation: GraphRelation): string => {
  const metadata = formatKeyValues(relation.metadata);
  const idPrefix = relation.id ? `[${relation.id}] ` : "";
  return `- ${idPrefix}${relation.source} --${relation.label}--> ${relation.target}${metadata ? ` - ${metadata}` : ""}`;
};
```

- [ ] **Step 2: Add EXISTING RELATIONS section to `buildUserMessage`**

Replace `buildUserMessage` (lines 388-401) with:

```ts
const buildUserMessage = (body: ExtractGraphBody): string => {
  const context = body.context ?? {};
  const existingEntities = context.existingEntities ?? body.existingEntities ?? [];
  const existingRelations = context.existingRelations ?? body.existingRelations ?? [];
  const recentConversation = context.recentConversation ?? body.recentConversation ?? [];

  return `EXISTING ENTITIES (use these spellings when the user refers to the same thing):
${formatList(existingEntities, 20, formatEntity)}

EXISTING RELATIONS (each prefixed with its [id] — use these IDs verbatim in supersedes when the user contradicts the relation):
${formatList(existingRelations, 30, formatRelation)}

RECENT CONVERSATION (for pronoun resolution only — do NOT extract from these turns):
${formatList(recentConversation, 4, formatConversationTurn)}

NEW UTTERANCE:
"""${body.text}"""`;
};
```

The cap at 30 mirrors the host's slice in `buildExtractionContext` (Task 4) — both ends agree.

- [ ] **Step 3: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/lib/extract-graph.ts
git commit -m "$(cat <<'EOF'
Render EXISTING RELATIONS [id] block in extractor prompt

formatRelation now prefixes [id] when present; buildUserMessage adds
an EXISTING RELATIONS section so the model can reference relations
verbatim by id in the supersedes field. Capped at 30 entries to mirror
the host-side cap in buildExtractionContext.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Teach the extractor when to emit supersedes (system prompts)

**Files:**
- Modify: `src/lib/extract-graph.ts:29-62` (`WIKI_EXTRACTOR_PROMPT`)
- Modify: `src/lib/extract-graph.ts:64-87` (`GRANULAR_EXTRACTOR_PROMPT`)

Both prompts get the same SUPERSEDES block — the trigger logic is mode-agnostic. The block goes after the existing RELATIONS section in each prompt, before the closing "If the utterance contains nothing..." line.

- [ ] **Step 1: Append SUPERSEDES section to WIKI_EXTRACTOR_PROMPT**

Replace lines 61-62 of `WIKI_EXTRACTOR_PROMPT` (the closing two lines that read `If the utterance contains nothing that passes the wiki-page test...` through `You are not the conversational agent.`) with:

```ts
SUPERSEDES — when the user contradicts the existing graph:
The user's utterance sometimes corrects, replaces, or denies a relation already shown in EXISTING RELATIONS. When that happens, return the contradicted relation's [bracketed] id in \`supersedes\`.

Trigger ONLY when the user explicitly:
  - negates a fact ("Maya isn't on Atlas")
  - replaces a fact ("It's not Maya, it's Sam")
  - says something that makes the prior fact mutually exclusive with the new one — and the entity referenced is the SAME entity.

Do NOT trigger when:
  - the user adds new info that coexists with the old ("Maya also helps Sam" — both can be true)
  - the user is vague or non-committal
  - the relation has the same endpoints but a slightly different label (those are fine alongside each other)

Reference relations by their [bracketed] id from the EXISTING RELATIONS list above. If you can't find an exact id match, do not invent one — omit the supersede.

If the utterance contains nothing that passes the wiki-page test, return empty arrays. Better an empty turn than wiki bloat.
Never speak to the user. You are not the conversational agent.\`;
```

(Make sure the closing backtick + semicolon are preserved — the SUPERSEDES block sits inside the same template literal.)

- [ ] **Step 2: Append SUPERSEDES section to GRANULAR_EXTRACTOR_PROMPT**

Replace lines 86-87 of `GRANULAR_EXTRACTOR_PROMPT` (the closing two lines `Return empty arrays only when...` through `You are not the conversational agent.`) with:

```ts
SUPERSEDES — when the user contradicts the existing graph:
The user's utterance sometimes corrects, replaces, or denies a relation already shown in EXISTING RELATIONS. When that happens, return the contradicted relation's [bracketed] id in \`supersedes\`.

Trigger ONLY when the user explicitly:
  - negates a fact ("Maya isn't on Atlas")
  - replaces a fact ("It's not Maya, it's Sam")
  - says something that makes the prior fact mutually exclusive with the new one — and the entity referenced is the SAME entity.

Do NOT trigger when:
  - the user adds new info that coexists with the old ("Maya also helps Sam" — both can be true)
  - the user is vague or non-committal
  - the relation has the same endpoints but a slightly different label (those are fine alongside each other)

Reference relations by their [bracketed] id from the EXISTING RELATIONS list above. If you can't find an exact id match, do not invent one — omit the supersede.

Return empty arrays only when the utterance has no extractable entities — small talk, hesitations, yes/no answers, filler tokens.
Never speak to the user. You are not the conversational agent.\`;
```

- [ ] **Step 3: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/lib/extract-graph.ts
git commit -m "$(cat <<'EOF'
Teach extractor when to emit supersedes

Both wiki and granular extractor prompts gain a SUPERSEDES section
that defines: trigger conditions (negates / replaces / makes prior
mutually exclusive), no-trigger conditions (adds info that coexists,
vague language, label variants), and the rule that ids must be quoted
from EXISTING RELATIONS verbatim — never invented.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Apply supersedes in the host (and un-supersede on re-assertion)

**Files:**
- Modify: `src/lib/journal-store.ts:80-99` (`ExtractedPayload`)
- Modify: `src/lib/journal-store.ts:129-239` (`mergeExtraction`)
- Modify: `src/routes/index.tsx:500-505` (the `graphOnly` patch in `processGraphUpdate`)

Two changes in `mergeExtraction`:
1. **Apply supersedes:** for each id in `payload.supersedes ?? []`, set `relations[id].supersededAt = now` (silent skip if missing or already superseded).
2. **Un-supersede on re-assertion:** when an incoming relation patch hits the existing-id branch (the relation already exists with the same `${src}__${label}__${tgt}` key), clear `supersededAt`. Re-assertion is the user's signal that the prior contradiction was wrong — self-healing the spec's "false positive" failure mode.

Plus a tiny tweak to the host call site: the explicit `graphOnly` override in `processGraphUpdate` strips `followUp` but must keep `supersedes`.

- [ ] **Step 1: Add supersedes to ExtractedPayload**

In `src/lib/journal-store.ts`, replace the `ExtractedPayload` interface (lines 80-99) with:

```ts
export interface ExtractedPayload {
  entities: Array<{
    name: string;
    type: Entity["type"];
    description?: string;
    metadata?: Record<string, string | number | boolean>;
    /**
     * Wiki-mode only: lines of questioning Lumen can pursue about this
     * entity. Granular extractor returns this empty (or absent).
     */
    questions?: string[];
  }>;
  relations: Array<{
    source: string;
    target: string;
    label: string;
    metadata?: Record<string, string | number | boolean>;
  }>;
  /**
   * Ids of relations the user contradicted. mergeExtraction sets
   * supersededAt on each. Silently skips missing or already-superseded ids.
   */
  supersedes?: string[];
  followUp?: { question: string; reason: string; targetEntityNames: string[] };
}
```

- [ ] **Step 2: Apply supersedes + un-supersede inside `mergeExtraction`**

In the same file, locate `mergeExtraction` (starts at line 129). Inside, after the `// relations` block finishes (the for-loop ending around line 195) and before the `// follow-up` block, insert the supersede-application step. Also tweak the relation upsert branch so re-assertion clears any prior supersede.

Replace the entire `mergeExtraction` function (lines 129-239) with:

```ts
export function mergeExtraction(
  prev: JournalState,
  text: string,
  payload: ExtractedPayload,
): { next: JournalState; entryId: string } {
  const now = new Date().toISOString();
  const entities = { ...prev.entities };
  const relations = { ...prev.relations };
  const followUps = [...prev.followUps];
  const askedQuestions = [...(prev.askedQuestions ?? [])];
  const entryEntityIds: string[] = [];
  const entryRelationIds: string[] = [];

  // entities
  const nameToId: Record<string, string> = {};
  for (const e of payload.entities ?? []) {
    if (!e?.name) continue;
    const id = slugify(e.name);
    nameToId[e.name.toLowerCase()] = id;
    const existing = entities[id];
    entities[id] = existing
      ? {
          ...existing,
          description: e.description || existing.description,
          metadata: { ...existing.metadata, ...(e.metadata ?? {}) },
          mentions: existing.mentions + 1,
          lastSeen: now,
          type: existing.type === "other" ? e.type : existing.type,
          questions: mergeQuestions(existing.questions, e.questions),
        }
      : {
          id,
          name: e.name,
          type: e.type ?? "other",
          description: e.description,
          metadata: e.metadata ?? {},
          mentions: 1,
          firstSeen: now,
          lastSeen: now,
          questions: mergeQuestions(undefined, e.questions),
        };
    entryEntityIds.push(id);
  }

  // relations
  for (const r of payload.relations ?? []) {
    const src = nameToId[r.source?.toLowerCase()] ?? slugify(r.source ?? "");
    const tgt = nameToId[r.target?.toLowerCase()] ?? slugify(r.target ?? "");
    if (!src || !tgt || src === tgt) continue;
    const rid = `${src}__${r.label}__${tgt}`;
    if (!relations[rid]) {
      relations[rid] = {
        id: rid,
        source: src,
        target: tgt,
        label: r.label,
        metadata: r.metadata ?? {},
        createdAt: now,
      };
    } else {
      // Re-assertion of an existing relation. If it was previously
      // soft-superseded, the user has now affirmed it again — clear the
      // supersede so it returns to the graph view + export. This is the
      // self-healing path for false-positive supersedes.
      const { supersededAt: _ignored, ...rest } = relations[rid];
      relations[rid] = {
        ...rest,
        metadata: { ...relations[rid].metadata, ...(r.metadata ?? {}) },
      };
    }
    entryRelationIds.push(rid);
  }

  // supersedes — apply AFTER the relations upsert so a supersede in the
  // same patch as a re-assertion of a different relation can't accidentally
  // hide a relation that was just (re-)created in this turn. The extractor
  // is told supersedes references EXISTING RELATIONS only, so collisions
  // here are the model's mistake, not ours.
  for (const id of payload.supersedes ?? []) {
    const target = relations[id];
    if (!target) {
      console.warn("[mergeExtraction] supersedes references unknown id:", id);
      continue;
    }
    if (target.supersededAt) continue;
    relations[id] = { ...target, supersededAt: now };
  }

  // follow-up
  if (payload.followUp?.question) {
    const targetIds = (payload.followUp.targetEntityNames ?? [])
      .map((n) => nameToId[n.toLowerCase()] ?? slugify(n))
      .filter(Boolean);
    const fu: FollowUp = {
      id: `fu-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      question: payload.followUp.question,
      reason: payload.followUp.reason ?? "",
      targetEntityIds: targetIds,
      createdAt: now,
      answered: false,
    };
    followUps.unshift(fu);
    const asked: AskedQuestion = {
      question: payload.followUp.question,
      targetEntityIds: targetIds,
      askedAt: now,
    };
    askedQuestions.unshift(asked);
    if (askedQuestions.length > ASKED_QUESTIONS_CAP) {
      askedQuestions.length = ASKED_QUESTIONS_CAP;
    }
  }

  const entryId = `je-${Date.now()}`;
  const entry: JournalEntry = {
    id: entryId,
    text,
    createdAt: now,
    entityIds: Array.from(new Set(entryEntityIds)),
    relationIds: Array.from(new Set(entryRelationIds)),
  };

  const next: JournalState = {
    entries: [entry, ...prev.entries],
    entities,
    relations,
    followUps,
    askedQuestions,
  };
  return { next, entryId };
}
```

- [ ] **Step 3: Preserve supersedes through the `graphOnly` override in `processGraphUpdate`**

In `src/routes/index.tsx`, locate the `graphOnly` patch inside `processGraphUpdate` (lines 500-505). It currently spreads `payload` and explicitly nulls `followUp`. Because spread keeps `supersedes`, no change is strictly required — but make the intent explicit. Replace lines 500-505 with:

```ts
        // Branch B: Gemini owns dialogue, so suppress any follow-up the
        // extractor produced. Keep entities, relations, AND supersedes —
        // the contradiction-detection patch must reach mergeExtraction.
        const graphOnly: ExtractedPayload = {
          ...payload,
          followUp: undefined,
        };
```

(Comment-only change — behavior is unchanged. The clarity matters: the next reader sees that `supersedes` is intentionally retained.)

- [ ] **Step 4: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/lib/journal-store.ts src/routes/index.tsx
git commit -m "$(cat <<'EOF'
Apply supersedes in mergeExtraction; un-supersede on re-assertion

ExtractedPayload gains supersedes: string[]. mergeExtraction now sets
supersededAt = now on each id (silently skipping unknowns / duplicates),
applied AFTER the relations upsert. The re-assertion branch — when an
incoming relation hits an existing id with matching src/label/tgt —
clears any prior supersededAt, self-healing false-positive supersedes.
Tightened the comment around graphOnly so the next reader sees that
supersedes intentionally survives the followUp suppression.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Compute `uncertainRelations` in `buildGraphSummary`

**Files:**
- Modify: `src/routes/index.tsx:537-623` (`buildGraphSummary`)

The live agent reads `uncertainRelations` to pick a probe target. Each active relation is scored 0–3 across three signals; top 3 with score ≥ 2 are surfaced. The cross-turn signal uses entry membership (NOT `entity.firstSeen` — those are millisecond-precision timestamps that always differ even within a single utterance, which would fire the signal for nearly every relation).

- [ ] **Step 1: Add the computation and expose the field**

In `src/routes/index.tsx`, locate `buildGraphSummary` (starts at line 537). Just before the final `return { ... }` (line 608), insert the `uncertainRelations` computation. Then add `uncertainRelations` to the returned object.

Replace `buildGraphSummary` (lines 537-623) with:

```ts
  // Snapshot of graph state shaped for the model's planner. Returned to the
  // model when it calls get_graph_summary. Keeping it minimal+structured
  // (rather than dumping raw entities/relations) is intentional: the model
  // uses these labels (thin / probed / justMentioned / bridgeCandidates /
  // uncertainRelations) to decide its next question without us hardcoding
  // a state machine.
  const buildGraphSummary = useCallback(() => {
    const s = stateRef.current;
    const conv = conversationRef.current;
    const sessionStartedAt = sessionStartRef.current ?? Date.now();
    const sessionElapsedMin = Math.round(((Date.now() - sessionStartedAt) / 60000) * 10) / 10;

    const relationCounts = new Map<string, number>();
    Object.values(s.relations).forEach((relation) => {
      relationCounts.set(relation.source, (relationCounts.get(relation.source) ?? 0) + 1);
      relationCounts.set(relation.target, (relationCounts.get(relation.target) ?? 0) + 1);
    });

    const allEntities = Object.values(s.entities);
    const entitiesWithCoverage = allEntities.map((entity) => {
      const words = entityWordCount(s, entity.id);
      return {
        name: entity.name,
        type: entity.type,
        coverage: coverageLabel(words),
        mentions: entity.mentions,
        relationCount: relationCounts.get(entity.id) ?? 0,
        openQuestions: entity.questions ?? [],
      };
    });

    const thinEntities = entitiesWithCoverage
      .filter((e) => e.coverage === "thin")
      .sort((a, b) => b.mentions - a.mentions)
      .map((e) => e.name);

    // Substring match against entity names is good enough here — the model
    // uses this as a soft signal ("don't re-ask Maya, just covered her") not
    // as ground truth. Cheaper than re-running NER on the conversation log.
    const sinceSession = conv.filter(
      (turn) => new Date(turn.createdAt).getTime() >= sessionStartedAt,
    );
    const probedNames = new Set<string>();
    for (const turn of sinceSession) {
      const lower = turn.text.toLowerCase();
      for (const entity of allEntities) {
        if (lower.includes(entity.name.toLowerCase())) probedNames.add(entity.name);
      }
    }

    const lastUserTurn = [...conv].reverse().find((turn) => turn.role === "user");
    const justMentioned: string[] = [];
    if (lastUserTurn) {
      const lower = lastUserTurn.text.toLowerCase();
      for (const entity of allEntities) {
        if (lower.includes(entity.name.toLowerCase())) justMentioned.push(entity.name);
      }
    }

    const bridgeCandidates = buildBridgingCandidates(s)
      .slice(0, 6)
      .map((bridge) => [bridge.a.name, bridge.b.name] as [string, string]);

    const recentAgentQuestions = conv
      .filter((turn) => turn.role === "agent")
      .slice(-5)
      .map((turn) => turn.text);

    // Aggregated question backlog across the wiki — flat (entity, question)
    // pairs the model can sample from. Empty in granular mode (entities have
    // no questions field) so the model falls back to its default probing.
    const openQuestionsTop = allEntities
      .flatMap((entity) =>
        (entity.questions ?? []).map((question) => ({ entity: entity.name, question })),
      )
      .slice(0, 12);

    // uncertainRelations — three additive signals (each +1 if true), 0–3
    // total. Top 3 active relations with score ≥ 2 are surfaced. Used by
    // the live agent's PRESUPPOSITIONAL PROBES policy.
    //
    // Cross-turn uses ENTRY MEMBERSHIP (not entity.firstSeen) because
    // firstSeen is an ms-precision ISO timestamp that almost always
    // differs even between entities first seen in the same utterance —
    // so the inequality check would fire for nearly every relation.
    const firstEntryOf = (entityId: string): string | undefined =>
      s.entries.find((entry) => entry.entityIds.includes(entityId))?.id;

    const uncertainRelations = Object.values(s.relations)
      .filter((r) => !r.supersededAt)
      .map((r) => {
        let score = 0;

        // Single-mention: relation appears in exactly one journal entry.
        const mentionCount = s.entries.filter((e) => e.relationIds.includes(r.id)).length;
        if (mentionCount <= 1) score += 1;

        // Cross-turn resolution: source and target first surfaced in
        // different entries.
        const sourceEntry = firstEntryOf(r.source);
        const targetEntry = firstEntryOf(r.target);
        if (sourceEntry && targetEntry && sourceEntry !== targetEntry) score += 1;

        // First-time pair: this is the only active relation between
        // these two entities.
        const pairCount = Object.values(s.relations).filter(
          (other) =>
            !other.supersededAt &&
            other.source === r.source &&
            other.target === r.target,
        ).length;
        if (pairCount <= 1) score += 1;

        return {
          source: s.entities[r.source]?.name,
          label: r.label,
          target: s.entities[r.target]?.name,
          score,
        };
      })
      .filter((r): r is { source: string; label: string; target: string; score: number } =>
        r.score >= 2 && Boolean(r.source) && Boolean(r.target),
      )
      .sort((a, b) => b.score - a.score)
      .slice(0, 3);

    return {
      sessionElapsedMin,
      mode: extractionModeRef.current,
      entityCount: allEntities.length,
      relationCount: Object.keys(s.relations).length,
      entities: entitiesWithCoverage
        .sort((a, b) => b.mentions - a.mentions)
        .slice(0, 30),
      thinEntities: thinEntities.slice(0, 10),
      probedThisSession: Array.from(probedNames).slice(0, 12),
      justMentioned,
      bridgeCandidates,
      recentAgentQuestions,
      openQuestionsTop,
      uncertainRelations,
    };
  }, []);
```

- [ ] **Step 2: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/routes/index.tsx
git commit -m "$(cat <<'EOF'
Compute uncertainRelations in get_graph_summary

Three additive signals score active relations 0-3:
  +1 single-mention (one journal entry references it)
  +1 cross-turn (source / target first appeared in different entries)
  +1 first-time pair (only active relation between these two entities)

Top 3 with score >= 2 are surfaced via the new uncertainRelations
field on the graph_summary payload, sorted by score desc. Cross-turn
deliberately uses entry-membership instead of entity.firstSeen — those
are ms-precision timestamps that always differ even when entities first
appeared in the same utterance.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Update `get_graph_summary` tool description

**Files:**
- Modify: `src/routes/index.tsx:628-638` (the `liveTools` memo)

The live agent reads the tool's description to decide when to call it. The new `uncertainRelations` field needs to show up there too so the model expects it.

- [ ] **Step 1: Mention uncertainRelations in the tool description**

In `src/routes/index.tsx`, locate the `liveTools` memo (lines 628-638). Replace it with:

```ts
  // Function declarations registered with Gemini Live at setup. Memoized so
  // the underlying client doesn't see a new array on every render (which
  // would imply a session restart was needed).
  const liveTools = useMemo<GeminiFunctionDeclaration[]>(
    () => [
      {
        name: "get_graph_summary",
        description:
          "Return the current state of the user's knowledge graph: which entities exist, which are thin (need probing), which were just mentioned, bridge candidates, and uncertainRelations (the top relations the host suspects might be wrong — phrase your next question as a presupposition over one of these per the PRESUPPOSITIONAL PROBES policy). Call this BEFORE deciding your next question.",
        parameters: { type: "OBJECT", properties: {} },
      },
    ],
    [],
  );
```

- [ ] **Step 2: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/routes/index.tsx
git commit -m "$(cat <<'EOF'
Mention uncertainRelations in get_graph_summary description

The model uses the tool description to decide when to call and what to
expect. Adding uncertainRelations here surfaces it before the system-
prompt extension lands, so the field is well-formed by the time the
PRESUPPOSITIONAL PROBES policy starts referring to it.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Add `PRESUPPOSITIONAL PROBES` to the live-agent system prompt

**Files:**
- Modify: `src/lib/conversation-policy.ts:284-342` (`GEMINI_LIVE_SYSTEM_INSTRUCTION`)

This is the final piece. The block goes after `HOW TO PICK YOUR NEXT QUESTION (...)` and before `ACTIVE LISTENING — the heart of how you talk:`. The cadence is self-regulated — the model reads its own recent turns to decide whether it has probed lately.

- [ ] **Step 1: Insert the PRESUPPOSITIONAL PROBES block**

In `src/lib/conversation-policy.ts`, locate `GEMINI_LIVE_SYSTEM_INSTRUCTION` (starts at line 284). Find the block that ends with `4. If nothing graph-shaped fits, ask an open elaboration grounded in what the user just said ("what was that like?", "what happened next?").` (around line 319). Just after that line (i.e. after the granular-mode tier-4 fallback), and before the line `ACTIVE LISTENING — the heart of how you talk:`, insert the new block.

Replace lines 319-321 (which currently read):

```
  4. If nothing graph-shaped fits, ask an open elaboration grounded in what the user just said ("what was that like?", "what happened next?").

ACTIVE LISTENING — the heart of how you talk:
```

with:

```
  4. If nothing graph-shaped fits, ask an open elaboration grounded in what the user just said ("what was that like?", "what happened next?").

PRESUPPOSITIONAL PROBES — implicit verification through natural questions:

When \`uncertainRelations\` in graph_summary is non-empty, the host has flagged some relations as worth quietly confirming. Each item is { source, label, target, score }, sorted by score desc (highest = most uncertain). At most three are returned.

CADENCE — soft 5-to-8-turn rhythm, self-regulated:
  Aim to weave one probe into your next question roughly once every 5–8 turns. The host does NOT track this for you — gauge it from your own recent turns (you can see them in recentAgentQuestions). If you can't recall presupposing an uncertain relation in your last ~8 turns, your next question should be a probe. Otherwise prefer a normal question from the tier ladder above.

STYLE — never sounds like a clarification:
  Do not ask "is X correct?", "did you say Y?", "I think you mentioned…", or anything that names the act of confirming. Instead, phrase a question that PRESUPPOSES the relation as true. The user's response either flows with it (silent confirmation — graph unchanged) or contradicts it (which the extractor catches automatically next turn). Either outcome is captured without further work from you. NEVER follow up to check whether you got it right.

  Suspect: Maya --on--> Project Atlas
  Bad:  "Did you say Maya was on Atlas?"
  Good: "How's Maya's piece of Atlas been going?"

  Suspect: user --lives_in--> Brooklyn
  Bad:  "Are you still in Brooklyn?"
  Good: "How's Brooklyn been treating you lately?"

  Suspect: Sam --works_with--> Maya
  Bad:  "Is Sam someone Maya works with?"
  Good: "How's Sam been finding it, working alongside Maya?"

The probe must be indistinguishable from a normal warm follow-up. The user must never feel quizzed or audited.

EXCEPTIONS — defer the probe even if the cadence would fire:
  - The user just shared something tender or emotionally heavy. Reflect first; the probe can wait.
  - A tier-1 bridge or tier-2 thin-entity move is more valuable right now. You can also PAIR them — "How did Maya end up on Atlas?" both bridges Maya↔Atlas AND probes the works_on relation.
  - \`uncertainRelations\` is empty. Skip this entire section.

ACTIVE LISTENING — the heart of how you talk:
```

(The escaped backticks are required because the surrounding template literal uses `\`` to embed backticks in the prompt text.)

- [ ] **Step 2: Type-check**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/lib/conversation-policy.ts
git commit -m "$(cat <<'EOF'
Add PRESUPPOSITIONAL PROBES policy to live-agent prompt

Slots a new block into GEMINI_LIVE_SYSTEM_INSTRUCTION after the
question-tier ladder. Defines:
  - cadence: soft 5-to-8 turns, self-regulated from recentAgentQuestions
  - style: presupposition (never "is X correct?"), with concrete
    bad/good examples for three relation shapes
  - exceptions: tender moments, tier-1 bridges (which can pair-and-probe),
    and the empty-uncertainRelations skip-the-section case

This is the final wiring task. End-to-end: extractor flags uncertain
relations -> get_graph_summary surfaces them -> live agent phrases a
probe -> user contradicts -> extractor emits supersedes -> host applies.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Manual smoke testing

**Files:**
- None (validation only)

The spec calls out four scenarios. The project has no automated test harness for the LLM loop, so we exercise each one by hand with the dev server and confirm observable behavior.

- [ ] **Step 1: Start the dev server**

```bash
npm run dev
```

Open the URL it prints (typically `http://localhost:5173`). Reload to ensure a clean state, then click the mic to start a session.

- [ ] **Step 2: Scenario A — Probe phrasing check**

Mention 4–5 entities with relations across a few turns:
- "Maya works on Project Atlas at Stripe."
- "Sam has been collaborating with Maya."
- "Brooklyn's been treating me well lately."

Then deliberately stall — give the agent two or three turns where you say very little ("yeah", "mm hm").

**Expected:** Within the next 5–8 turns, the agent's question should feel like a normal warm follow-up but presuppose one of the relations you mentioned (e.g. "How's Maya's piece of Atlas been going?").

**Failure modes:**
- The agent says "Did you say…?" or "Is it right that…?" → the prompt's STYLE section needs more anti-pattern examples.
- The agent never probes → the CADENCE section's wording isn't strong enough; consider strengthening "your next question should be a probe".

- [ ] **Step 3: Scenario B — Contradiction roundtrip**

Continuing the same session, contradict a relation directly: "Actually Maya's at Anthropic, not Stripe."

**Expected:** Within one turn:
1. The `Maya --works_at--> Stripe` relation drops from the graph view.
2. A new `Maya --works_at--> Anthropic` relation appears.
3. Open devtools → Application → localStorage → `lumen.journal.v1`. Find the relations dict; the old relation's id (e.g. `maya__works_at__stripe`) should have a `supersededAt` ISO timestamp set.

Then trigger an Obsidian export (download icon in the top-right pill). Unzip the result and check Maya's note — it should NOT list the Stripe relation under outgoing edges.

**Failure modes:**
- Old relation still shows on graph → check Task 2 filter; check `supersededAt` is actually set in localStorage.
- Old relation appears in export → check Task 3 filter.
- `supersededAt` not set → confirm the extractor returned `supersedes` in the function call (devtools → Network → the `generateContent` POST → response → look for `"supersedes": [...]` in the function call). If empty, the prompt's SUPERSEDES section needs strengthening.

- [ ] **Step 4: Scenario C — False-positive watch (run for ~20 minutes)**

Have a longer free-form session — at least 20 minutes, mention many entities, vary topics. After:
1. Open localStorage and grep for `supersededAt` entries.
2. For each, ask: did the user actually contradict that relation, or is this a false positive?

Each false positive is a case to fold into the extractor prompt's `Do NOT trigger when:` list. **Note them but don't act on them in this PR** — adjustments to the prompt belong in a follow-up tuning round.

- [ ] **Step 5: Scenario D — Cadence sanity check**

Across the same 20-minute session, count how many of the agent's turns presupposed an uncertain relation (count by ear or scroll the conversation log). Aim for one probe roughly every 5–8 agent turns.

**Failure modes:**
- Probes too frequent (>1 every 4 turns): strengthen the EXCEPTIONS section ("defer otherwise").
- Probes never fire (0 across 20 min): check that `uncertainRelations` is non-empty in the `get_graph_summary` response (devtools → Network → look at the `toolResponse` payload). If non-empty but no probes, strengthen "your next question should be a probe" in CADENCE.

- [ ] **Step 6: Final type-check + lint sweep**

```bash
npx tsc --noEmit
npm run lint
```

Both should PASS.

- [ ] **Step 7: No commit needed for testing**

If the smoke tests surface bugs, fix them in fresh commits (each on the relevant earlier task's file). If they pass, the feature is ready for review.

---

## Done criteria

- All 12 tasks complete; `npx tsc --noEmit` and `npm run lint` clean.
- Manual scenarios A–D pass with the failure-mode notes recorded for any prompt-tuning follow-ups.
- The plan + spec are committed and the working branch's diff covers only the spec, plan, and the listed source files.
