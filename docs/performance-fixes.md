# Performance fixes: what changed, and how we know the output didn't

This applies the fixes from [the complexity audit](complexity-audit.md), which built on [the latency audit](latency-audit.md). Each section covers one fix:
- what it costs before and after;
- the files it touches;
- the evidence that its output is unchanged;
- what it measured.

**The rule for every fix:** same output as before, in less time. There are two deliberate exceptions: tie order, described under [Intended behaviour change](#intended-behaviour-change), and the graph layout's approximate charge, [6b](#6b-applied-separately-barneshut-charge-liblogicgraph_layoutdart). Fixes in app code ship with an equivalence test that runs the original code, kept verbatim under `test/support/`, side by side with the new code.

**Notation:** V = entities, R = relations, N = journal entries, T = text length, L = longest entity name, k = items returned.

## At a glance

Measured at 1,000 entities, as host-VM medians; an iPhone is roughly 2–4× slower. "Prototype" numbers come from the audit, not from the code applied here.

| # | Fix | Before | After | Measured | Evidence |
|---|---|---|---|---|---|
| 1 | Bridge candidates (`buildAgenda`) | O(V²·d) pairs + full sort | Wedge counting + top-k: O(Σdeg²) | whole agenda 223 → 6.1 ms (37×) | `agenda_equivalence_test` |
| 2 | Relation count per entity (graph summary) | O(V·R) | Degree map: O(V+R) | whole summary body 256 → 5.7 ms (45×) | `graph_summary_test` |
| — | Graph summary memoized per state | Rebuilt per tool call | O(1) on repeat calls in a turn | repeat calls skip the 5.7 ms | provider code, by construction |
| 3 | Transcript highlighting | One regex per entity per call: O(V·T) | Trie, cached per term list: O(T·L) | 25 → 0.08 ms per turn (298×) | `entity_highlighter_equivalence_test` |
| 4 | `get_entity_mentions` | Reads every entry of the user: O(N) | Posting list + B-tree: O(log N + k) | 9.4 ms → 0.036 ms at 60k entries (prototype) | migration, **not yet run** |
| 5 | RLS policies | `auth.uid()` per row | `(select auth.uid())`, once per query | 45 ms → 15 ms on a 60k-row scan (prototype) | migration, **not yet run** |
| 6 | Graph layout forces | O(n²) all pairs, twice | Grid **not applied** (measured slower); charge now Barnes–Hut, see 6b | 2,000 bodies: 65 → 25 ms per tick (2.6×) | `graph_layout_quality_test` |
| 7 | "Which names are in this text" (3 places) | O(V·T) | Trie: O(T·L) | same class as #3 | equivalence tests, Dart and TS |
| 8 | `user_entities` view | Group-by on every read: O(M log M) | Trigger-maintained table: O(1) per slug read | 28 ms per call → index read (analysis) | migration, **not yet run** |
| 9 | `retrieve-memory` index + communities | Rebuilt every request | Per-user LRU cache; communities only when needed | 77.6 → 13.3 ms per warm recall (5.8×) | `handler.cache.test.ts` |
| 10 | Turn match in mentions | Scan the notebook's user turns | md5 expression index | linear → index probe | migration, **not yet run** |
| 11 | Context fitting | O(k·M) re-count | **not applied**, see below | — | — |
| 12 | Other agenda work | Re-tokenize per entity; full sorts | Word counts once; top-k | included in #1 | `agenda_equivalence_test` |

The three migrations have **not been run against a database**. Docker stopped during this work, so neither the pgTAP suite nor `supabase/tests/perf/rpc_timings.sql` has run against them. See [Before deploying](#before-deploying).

## Intended behaviour change

Dart's `List.sort` is not stable. Before, when two candidates had equal scores, their order depended on the sort's internals and on map iteration order. That affected thin entities, uncertain relations and bridge candidates.

The new top-k selection breaks ties by first appearance, with lower node index first for bridges. Where the old code had a well-defined order, the output is identical. Where it was arbitrary, it is now deterministic: the same state always gives the same agenda.

The equivalence tests check this as follows:
- **Untied fields match exactly:** `justMentioned`, open questions and counts.
- **Ranked lists hold the same scores in the same order:** thin entities by mentions, uncertain relations by score, bridges by shared-neighbour count.
- **Only ties can differ.** When several items share the score at the last slot, which of them fills it may differ, because the old choice was arbitrary.

`test/perf/dsa_alternatives_test.dart` goes further for bridges. It reproduces the old unstable sort exactly, and gets the identical top 6.

## The fixes

### 1 and 12. The agenda (`lib/logic/agenda.dart`)

**Before:**
- For every pair of active entities, the old code walked one neighbour list looking for shared neighbours. That cost O(V²·d), and it sorted all pairs to keep 6.
- Thin entities and uncertain relations also fully sorted their lists to take 10 and 3.
- Word counts were re-tokenized for every entity on an entry.

**After:**
- **Bridges, by wedge counting.** For each middle node m, every pair of its neighbours (a, b) shares m. Counting `shared[a·n+b]` over all middle nodes visits O(Σdeg²) wedges, not O(V²) pairs. Pairs that are directly linked are skipped, as before.
- **`_topK`.** A bounded, stable selection: O(n log k) instead of O(n log n).
- **Words counted once per entry.**
- **`justMentioned`** uses `NameTrie` (see #7).

**Evidence:**
- `test/agenda_equivalence_test.dart` runs `legacyBuildAgenda` (the original, verbatim, in `test/support/legacy_agenda.dart`) against the new code. It covers 4 fixed graphs and 30 random graphs of up to 300 entities.
- Every field is compared. Tie order is compared by score sequence, as explained above.

### 2. Graph summary (`lib/logic/graph_summary.dart`, `lib/providers/journal_provider.dart`)

**Before:** `_buildGraphSummary` counted each entity's relations by scanning every relation, O(V·R). It rebuilt the whole agenda on every `get_graph_summary` tool call, and Gemini can make several in one turn.

**After:**
- **A pure function.** `graphSummaryBody(state, lastUserText:)` builds the body, so it is testable without a provider. It makes one degree map, O(V+R), and uses set lookups for coverage.
- **A one-entry cache.** `JournalNotifier._summaryCache` is keyed on `identical(state)` plus the last transcript. `JournalState` is immutable and replaced on every commit, so identity is an exact "nothing changed" test.
- **Per-call fields stay fresh.** `recentAgentQuestions` and `sessionElapsedMin` change between calls with no state change, so they are added after the cache, every call.

**Evidence:** `test/graph_summary_test.dart` compares the body with the original, inline logic.

### 3. Highlighting (`lib/logic/entity_highlighter.dart`)

**Before:** `highlightRuns` re-sorted the terms on every call. It then ran one case-insensitive, whole-word regex per term over the text, and claimed hits longest-term first. This ran for every visible turn on every streamed chunk.

**After:**
- **A cached matcher.** A `_TermMatcher` holds a trie over the lower-cased terms. It is cached per terms list with an `Expando`, so a list that is reused costs nothing to rebuild.
- **One walk.** The text is walked once, from each word start, and the end boundary is checked at each match.
- **The same claiming as before.** Hits are processed in the same order the regexes ran: by term rank, then position. A per-rank scan cursor reproduces where each regex would resume after a match, so overlapping hits resolve exactly as they did.
- **A safe fast path.** It applies only when `toLowerCase` and the regex's case folding agree on every code unit: all units ≤ U+024F, except ſ (U+017F) and µ (U+00B5). Other input falls back to the original regex path, kept as `_highlightRunsRegex`.

**Evidence:** `test/entity_highlighter_equivalence_test.dart` compares the output with a verbatim copy of the regex implementation. It runs 15 edge cases and 300 random rounds:
- overlapping and nested terms;
- punctuation boundaries;
- repeated terms;
- non-Latin text, which takes the fallback path.

### 4 and 10. Entity mentions (`supabase/migrations/20261025000100_entity_mentions_index.sql`)

**Before:** `get_entity_mentions` filtered `journal_entries` with `entity_ids @> array[id]`. No index narrows that per entity, so every call read all of the user's entries. Each mention's turn was then found by scanning the notebook's user turns for equal text.

**After:**
- **A posting list.** `entry_entities` holds one row per (entry, entity), with a B-tree on `(user_id, entity_id, created_at desc, entry_id desc)`. The page is the index's first k rows, and the total is an index-only count.
- **Kept current by a trigger.** An `AFTER INSERT OR UPDATE OF entity_ids, user_id, notebook_id, created_at` trigger on `journal_entries` maintains it. It covers every writer, `commit_notebook` and LM-29's `remove_entity` included, so neither function had to change. Deletes cascade through the foreign key.
- **Locked to the trigger.** Clients can read their own rows but cannot write the table.
- **The turn match uses an index.** An index on `(notebook_id, speaker, md5(text), spoken_at desc)` serves it. The query keeps `ct.text = p.text` alongside the md5 equality, so a hash collision cannot change the answer.
- **Same signature, JSON, order and paging** (`p_before` exclusive). The backfill fills the table in the same migration.

**Why not the audit's `turn_id` column on entries:** it would change `_commit_apply_turn`, which LM-04 and LM-29 also edit. The index gives the same lookup with no write-path change.

### 5. RLS init plans (`supabase/migrations/20261025000000_rls_initplan.sql`)

**Before:** policies said `auth.uid() = user_id`. Postgres inlines `auth.uid()`, which parses the JWT claims, and re-evaluates it for every row it checks.

**After:** 33 `alter policy` statements wrap it as `(select auth.uid())`. That is an init plan, evaluated once per query. Each policy keeps its name, command and meaning. `conversation_turns` insert keeps its notebook-ownership check.

### 6. Not applied: a grid for the graph layout (`lib/logic/graph_layout.dart`, unchanged)

The audit proposed a uniform grid for the charge and collision forces, on the grounds that both are cut off at a distance. It was built and measured, then reverted, because it made the layout slower:

| Variant | 300 nodes | 2,000 nodes |
|---|---|---|
| All pairs (current) | 1.9 ms per tick | 70 ms per tick |
| Grid for charge and collision | 11.8 ms | 456 ms |
| Grid for collision only | 1.8 ms | 56 ms |

**Why the audit's analysis was wrong:**
- **The cutoff is too wide.** The charge cutoff is 320px, but gravity packs a settled graph tight: nodes rest about 35px apart. So 2,000 nodes span only about four cutoffs.
- **The neighbourhood is most of the graph.** A body's 3×3 cells hold most of the graph, so the grid still checks nearly every pair.
- **The sort adds cost.** Keeping the sums bit-identical needs neighbours in index order, so each body also paid a sort.
- **The collision-only grid isn't worth it.** It gains about 18%, but collision is order-sensitive within a tick, so it could only be checked on outcome, not on output. That's not worth it for a 2 ms tick at today's sizes.

**What would work, and why it's your call:** the charge pass is the cost. An exact method can't remove it at this density. Barnes–Hut (a quadtree, O(n log n)) is what d3-force uses on the web app with θ = 0.9. It approximates distant bodies by their centre of mass, so positions would differ slightly from today's Flutter layout. That trade is worth taking before the Memory screen (LM-27) draws 2,000 nodes. It changes output, so it was done separately, as 6b.

### 6b. Applied separately: Barnes–Hut charge (`lib/logic/graph_layout.dart`)

**Before:** the charge pass compared every pair, O(n²) per tick.

**After:** above 64 bodies (`GraphLayout.exactChargeLimit`), a quadtree is rebuilt each tick, with θ = 0.9 as on the web. At 64 bodies or fewer, the original all-pairs loop runs unchanged. Link, gravity, integration and collide are untouched.
- **The cutoff stays exact.** d3 tests the 320px cutoff against a cell's centre of mass. That pulls in whole cells that straddle it. Here a cell is skipped only when its bodies' bounding box lies wholly beyond 320px. It stands in for its bodies only when the box lies wholly inside 320px and the opening test passes. Cells that straddle the cutoff are opened. d3's looser rule ran the pass twice as fast, but its median per-body error was 14% rather than 1.5%.
- **The jiggle stays.** Opened leaves apply each body exactly, with the same rule: closer than 1px, a tiny random push at d² = 1.
- **Typed arrays.** The hot loop reads `Float64List`s and allocates no `Offset` per pair, so 300 bodies get faster too.

**Evidence:** `test/graph_layout_quality_test.dart` settles the same graphs with the new code and with the all-pairs original, kept as `test/support/legacy_graph_layout.dart`:

| Settled graph | All pairs | Barnes–Hut |
|---|---|---|
| 300 bodies: overlaps, box | 0, 976×963 | 0, 979×954 |
| 2,000 bodies: overlaps, box | 51, 1734×1732 | 70, 1739×1726 |

- **Overlap counts vary between runs.** Settling is chaotic: across spawn seeds the all-pairs layout itself ends with 46–66 overlaps at 2,000 bodies, and Barnes–Hut with 45–70.
- **Charge stays close.** On one tick from the same settled 600-body state, the median charge error is 1.5% of the typical charge; p95 is 3.9%.
- **Small graphs are exact.** At 64 bodies, positions match the original bit for bit.
- **The slow case is tagged.** The 2,000-body case is tagged `perf`, since the all-pairs reference takes about 25 s.

**Measured** (`flutter test test/perf/graph_layout_bench_test.dart`, host-VM median per tick):

| Layout state | 300 bodies | 2,000 bodies |
|---|---|---|
| Just spawned, in a pile | 1.81 → 1.28 ms | 48 → 20 ms (2.4×) |
| Settled, reheated | 1.78 → 1.12 ms | 65 → 25 ms (2.6×) |

**Collide is now the cost.** At 2,000 settled bodies, charge takes about 9 ms per tick (0.5 ms of it building the tree), down from about 45 ms. Collide, still all pairs, takes about 18 ms. A 2,000-body tick still misses a 60 fps frame, especially on a phone (2–4× slower). The next lever is collide, for example with the collision-only grid above, checked on outcome.

### 7. Name matching (`lib/logic/name_matcher.dart`, `src/lib/graphloop/name-matcher.ts`)

**Before:** three places tested `text.contains(name)` for every name: O(V·T).
- the agenda's `justMentioned`;
- `compileExtractionContext`'s exact-name ids;
- graphloop's `retrieve` exact-name seeds.

**After:** `NameTrie`, in Dart and TS, builds a trie over code units. `containedIn(text)` walks it from each position: O(T·L), whatever V is. It gives exactly `contains`'s answer, including that an empty key is always contained. Each caller keeps its own normalization and boundary rule.
- `extraction_context.dart` also replaces `entities.any(...)` de-duplication with a set.
- `retrieve.ts` replaces `Math.max(...spread)`, which can overflow the stack on large graphs, with loops.
- `scripts/sync-graphloop.mjs` now vendors `name-matcher.ts` into `supabase/functions/_shared/graphloop/`.

**Evidence:**
- `test/extraction_context_equivalence_test.dart`;
- the agenda equivalence test;
- graphloop's vitest suite;
- `node scripts/check-graphloop-sync.mjs`.

### 8. The user-wide entity view (`supabase/migrations/20261025000200_user_entity_stats.sql`)

**Before:** `user_entities` grouped all of a user's entity rows on every read.

**After:**
- **A maintained table.** `user_entity_stats` holds one row per (user_id, slug), with an index on `(user_id, mentions desc, last_seen desc, id)`.
- **Refreshed by a trigger.** A row trigger on `entities` refreshes exactly the slugs a write touches. It fires on insert, delete, and update of the aggregated columns, so `metadata`, `questions` and `description_source` edits skip it.
- **The same rules as the old view.** The refresh recomputes the slug from its source rows with the view's own aggregate expressions, including the tie-break. It is not an incremental `mentions += n`, so it cannot drift.
- **The view keeps its name and shape.** `user_entities` is replaced, with the same columns in the same order, to select from the table. `get_user_graph`, the grants and every other reader are unchanged.

**Not done:** `user_relations` stays a view. It is smaller, and its `active` rule compares supersessions across notebooks. Materialize it the same way if it shows up in timings.

### 9. Recall caching (`supabase/functions/retrieve-memory/handler.ts`, `src/lib/graphloop/retrieve.ts`)

**Before:** every request built a new `SearchIndex` over all entities and ran Louvain community detection. The communities are used only when no entity matches.

**After:**
- **One index per user and scope.** A module-scope LRU (32 entries) holds one `SearchIndex` per `user:scope`. Warm edge isolates reuse it, and `sync` re-indexes only entities whose content hash changed.
- **No races within an isolate.** A per-key promise chain serializes requests for the same key.
- **Communities on demand.** `RetrieveDeps.communitiesFor` passes them as a thunk, so Louvain runs only on the no-seed path.
- **Never shared between users.** Keys include the user id, and the cache is per isolate.

**Evidence:** `handler.cache.test.ts` covers reuse per user and scope, separation between users, and the no-match path. The existing handler tests pass unchanged.

### 11. Not applied: incremental token counting

`compileExtractionContext` re-counts the prompt after each item it adds. That is O(k·M) in theory, but the loop is capped at 54 additions and measures ≤1 ms. A running total would have to reproduce the joiner and section-header costs exactly, and any drift would change which items fit. The risk outweighs a sub-millisecond gain.

## Instrumentation added along the way

- **`vlog` timestamps.** It now prints a monotonic timestamp: `[voice][area] @<ms> message`. Any two log lines give an elapsed time.
- **Reply-audio start.** `GeminiLiveClient` logs `gemini → reply audio starts` on the first audio chunk of each reply. That is the moment the user hears Lumen, the end point of turn latency.

## Measurements

Reproduce with:

```bash
flutter test test/perf/applied_fixes_bench_test.dart --reporter expanded
```

```bash
deno test --allow-env --no-check supabase/functions/retrieve-memory/handler.cache.test.ts
```

"Before" runs the original code from `test/support/`, whose function bodies are checked byte for byte against commit `e80a6fb`. The highlighter copy includes the original's compiled-pattern cache, so the comparison is like with like. Host-VM medians:

| Path | Size | Before | After | Gain |
|---|---|---|---|---|
| `buildAgenda` | 200 entities | 12.4 ms | 2.1 ms | 6× |
| `buildAgenda` | 1,000 entities | 223 ms | 6.1 ms | 37× |
| Graph summary body | 200 entities | 10.1 ms | 1.25 ms | 8× |
| Graph summary body | 1,000 entities | 256 ms | 5.7 ms | 45× |
| Highlight one turn, same terms list | 200 terms | 7.4 ms | 0.31 ms | 24× |
| Highlight one turn, same terms list | 1,000 terms | 25 ms | 0.08 ms | 298× |
| Highlight one turn, new terms list (trie built) | 1,000 terms | 25 ms | 1.6 ms | 16× |
| Recall (`retrieve-memory`, no network) | 1,000 entities | 77.6 ms, every request | 13.3 ms when warm | 5.8× |

The audit's isolated prototypes (`test/perf/dsa_alternatives_test.dart`) agree:
- bridges 83× (156× with top-k);
- relation counts 72×;
- highlighting 256×.

**What it means for a turn.** Gemini's `get_graph_summary` tool call blocks Lumen's reply. At 1,000 entities it no longer costs a quarter of a second on the host VM, which is about 0.5–1 s on a phone. The transcript also stops re-running 1,000 regexes per visible turn on each streamed chunk.

## Test status

Run on this branch after all changes:

| Suite | Result |
|---|---|
| `flutter test --exclude-tags perf` | 577 passed (after 6b) |
| `flutter test test/perf/` | 34 passed (after 6b) |
| `flutter analyze` | no issues |
| `deno test --allow-env --no-check supabase/functions/` | 32 passed, including the 4 cache tests |
| `npx vitest run` (graphloop and web) | 98 passed |
| `cd infra && npm test` | 71 passed |
| `node scripts/check-graphloop-sync.mjs` | in sync |
| `supabase test db` (pgTAP) | **not run**: Docker was down |
| `supabase/tests/perf/rpc_timings.sql` | **not run**: Docker was down |

`deno check` reports type errors on the graphology imports. They are on `main` too, so the Deno suite runs with `--no-check`.

## Before deploying

Deploy order, on staging first:

1. `20261025000000_rls_initplan.sql`. This has no dependencies.
2. `20261025000100_entity_mentions_index.sql`. The backfill reads every journal entry once.
3. `20261025000200_user_entity_stats.sql`. The backfill groups every entity row once.

Then deploy the `retrieve-memory` function.
- The Flutter changes need no server change and can ship in any order.
- The migrations only replace read paths with the same output, so they are safe to apply before or after the app.

Checks to run on staging, which this branch could not:
- `supabase test db`. The existing `user_memory_test.sql` and `conversation_modes_test.sql` exercise `user_entities` and `get_entity_mentions` through the new tables.
- `psql -f supabase/tests/perf/rpc_timings.sql` for before and after timings.
- After a commit and after `remove_entity`, check that `entry_entities` and `user_entity_stats` match a fresh recomputation:

```sql
select count(*) from (
  select je.id, x from journal_entries je, unnest(je.entity_ids) x
  except select entry_id, entity_id from entry_entities
) d;  -- expect 0
```
