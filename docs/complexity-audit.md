# Complexity audit: the expensive operations, and faster structures that keep the same output

This follows [the latency audit](latency-audit.md). That one found *where* time goes. This one traces *why*, in the code's complexity, and proposes data structures and algorithms that produce the same result in less time.

**Notation:** V = entities in a notebook (or a user's merged graph), R = relations, N = journal entries, T = length of a piece of text, L = longest entity name, d = average degree and Δ = the change a single turn makes.

**How the claims were checked:**
- Every Dart replacement marked **verified** is prototyped in `test/perf/dsa_alternatives_test.dart` and asserted to produce output identical to today's code, on fixed and random graphs, before it's timed.
- SQL replacements were timed on the local stack in rolled-back transactions.
- Rows marked **analysis** are traced from the code but not prototyped.

## Applied

These fixes are now in the code. [Performance fixes](performance-fixes.md) records what changed, the equivalence evidence and the measured before and after.
- **Applied:** #1–#5, #7, #9, #10 (as an md5 index, not a `turn_id` column) and #12.
- **#8 applied:** as a trigger-maintained table.
- **Not applied:**
  - **#6.** The grid measured slower: the charge cutoff covers most of a settled graph.
  - **#11.** The gain is under 1 ms, and a running total risks drift.
- **Migrations not yet run:** #4, #5, #8 and #10 are migrations that haven't run against a database yet.

## Summary

| # | Operation, and where it runs | Today | Replacement | Gain at 1,000 entities | Status |
|---|---|---|---|---|---|
| 1 | Bridge candidates in `buildAgenda` (each `get_graph_summary` call) | O(V'²·d) pair loop, plus a full sort | Count common neighbours from each middle node, then a top-6 selection: O(Σdeg² + B log 6) | 207 ms → 1.2–2.3 ms (92–173×) | verified |
| 2 | Relation count per entity in `_buildGraphSummary` | O(V·R) scan | One degree map: O(V+R) | 27 ms → 0.5 ms (54×) | verified |
| 3 | Transcript highlighting, `highlightRuns` (each visible turn, each streamed chunk) | O(V log V + V·T): one regex per entity, terms re-sorted each call | Trie built once per term set, one pass: O(T·L) | 6.1 ms → 0.02 ms per turn (288×) | verified |
| 4 | Entity mentions, `get_entity_mentions` (3 per recall, the note page) | O(N_user): reads every entry of the user, then filters `entity_ids @>` | Posting-list table `entry_entities (user_id, entity_id, created_at desc)`: O(log N + k) | 9.4 ms → 0.036 ms at 60k entries (260×), and stays flat as entries grow | measured |
| 5 | RLS on every table: `auth.uid() = user_id` | Re-evaluated per row (inlined, includes a JSON parse) | `(select auth.uid())` in each policy: evaluated once per query | 45 ms → 15 ms on the 60k-row scan (3×), same rows | measured |
| 6 | Graph layout: charge and collision (every frame while moving) | O(n²) all pairs, twice | Uniform spatial grid (cell = cutoff distance): O(n + close pairs). Exact, because both forces are cut off | ~1.7 ms at 300 nodes today, ~75 ms projected at 2,000 | **measured: slower** (456 ms at 2,000), not applied. See performance-fixes.md |
| 7 | Which entity names appear in this text (3 places, see below) | O(V·T) substring test per entity | One trie or automaton per name set, walked once: O(T·L) | Same class of gain as #3 | analysis (same structure as #3) |
| 8 | User-wide graph, `user_entities` view (every recall and the Memory screen) | Group-by over all the user's entity rows on every call: O(M log M), M = rows across notebooks | Maintained `user_entity_stats` table, upserted by the commit (O(log M) per write), with a `(user_id, mentions desc)` index for top-k reads | 28 ms per call → index read of the top 2,000 | analysis |
| 9 | Recall index and communities in `retrieve-memory` (every recall) | New `SearchIndex` per request: O(V·tokens). Louvain O(R·iterations) every time | Keep the index per user in module scope and sync only changed entities (the class already supports it): O(Δ). Run communities only when there are no seeds, cached by graph version | ~41 ms → a few ms when warm | analysis |
| 10 | Turn match in `get_entity_mentions` (per mention) | Lateral scan of the notebook's user turns for equal text: O(turns) | Record `turn_id` on the entry at commit: O(1) join. Already a follow-up from LM-06 | small now, linear in notebook length | analysis |
| 11 | Context fitting in `compileExtractionContext` (every turn) | Rebuilds and re-counts the whole prompt after each added item: O(k·M) | Running token total, adding each item's own cost: O(k) | ≤1 ms today (capped), so low priority | analysis |
| 12 | Other `buildAgenda` work | Tokenizes each entry once per entity on it; full sorts to take the top 10 and top 3 | Count each entry's words once (or keep counts updated per commit); bounded top-k selection | small next to #1 | analysis |

Two structural changes cut repeated work across several rows:

- **Memoize the agenda per notebook state.** `JournalState` is immutable and replaced on each commit. Gemini can call `get_graph_summary` several times in one turn, and each call rebuilds everything. A cache keyed by `identical(state)` (plus `lastUserText` for the one field that reads it) turns those repeats into O(1).
- **Keep derived indexes alive.** The trie for #3 and #7, the degree map for #2 and the adjacency for #1 change only when the graph changes. Building them on commit, O(Δ), instead of on every read is the general fix.

## Details

### 1. Bridge candidates (`lib/logic/agenda.dart`, lines 80–110)

**Today:**
- Builds the neighbour sets, then loops over every pair (i < j) of the V' entities that have any relation.
- For each pair it builds two lists and a joined string key, checks `directlyLinked`, and intersects the two neighbour sets.
- Every bridge found is then fully sorted, just to take 6.
- That's O(V'²·d) time and O(V'²) short-lived strings, so the garbage collector also works.

**Replacement:** a pair (a, b) has `shared` = |N(a) ∩ N(b)|, which is exactly the number of middle nodes m with both a and b in N(m).
- So for each m, count every pair of its neighbours, using an integer key i·n + j: O(Σ_m deg(m)²). For sparse personal graphs (d ≈ 3) that's close to linear in R.
- Drop directly linked pairs.
- Keep the best 6 in a bounded list: O(B log 6) instead of O(B log B).

**Ties:** today's sort is Dart's `List.sort`, which isn't stable. So when several pairs share the top count, which ones make the cut is an accident of the sort algorithm.
- The prototype reproduces that exactly, by sorting the same list in the same order; that's how equivalence is proven.
- The recommended version breaks ties deterministically (more shared neighbours, then pair order). That's a small, intended behaviour change: the same graph always gives the same suggestions.

### 2. Relation count per entity (`lib/providers/journal_provider.dart`, `_buildGraphSummary`)

**Today:** each entity in the answer does `state.relations.values.where(...)`, so O(V·R).

**Replacement:** one pass over the relations, incrementing both endpoints (a self-loop counts once, as today), then an O(1) lookup per entity.

`thinEntities.contains` on a list inside the same loop should use a set. It's only 10 items today, but it's free.

### 3. Highlighting (`lib/logic/entity_highlighter.dart`)

**Today:**
- On every call, sorts all V terms by length.
- Then runs V compiled regexes over the text.
- It's called for each visible transcript turn on every rebuild, and for the live words in the pill on every streamed chunk.

**Replacement:** a trie of the lower-cased terms, built once when the term set changes. Walk it from each word start. Keep the same rules:
- whole word on both sides, using the same Unicode letter and number test;
- case-insensitive;
- longest term first when mentions overlap.

Text whose lower-case form changes length (a few Unicode characters) falls back to today's regex path, so offsets stay correct.

Cost per turn becomes O(T·L), independent of V. Also cache the runs of finalized turns by `(turnId, termsVersion)`; their text never changes, so only the streaming turn needs work.

### 4. Entity mentions (`get_entity_mentions`, from LM-06)

**Today:** the query filters on `entity_ids @> array[id]`, which no index can narrow for a given user.
- The plan reads every one of the user's entries through the `(user_id, created_at)` index, then filters.
- A GIN index on `entity_ids` didn't change the plan at this data shape.
- The `total` count does the same scan again.

**Replacement:** a posting list, `entry_entities (user_id, entity_id, created_at, entry_id)`.
- The commit writes it from `entry.entityIds` in the same transaction; LM-29's removal deletes from it.
- A B-tree on `(user_id, entity_id, created_at desc)` serves "newest 5" and "count" directly.
- Keyset paging on `(created_at, entry_id)` also fixes the page-boundary edge case LM-06 noted.

### 5. RLS policies (all migrations since `20260518000000`)

**Today:** `using (auth.uid() = user_id)`. Postgres inlines `auth.uid()` (a `current_setting` call plus a JSON parse) and evaluates it for every row it filters.

**Replacement:** `using ((select auth.uid()) = user_id)`. This becomes an init plan, evaluated once per query. It's Supabase's own recommendation, the rows returned are identical, and it's a policy-only migration with no code change.

### 6. Graph layout (`lib/logic/graph_layout.dart`, `step()`)

**Today:**
- Charge loops every ordered pair, skipping those beyond `chargeMaxDistance` (320).
- Collision loops every unordered pair, skipping those beyond the summed radii plus padding.
- Both are O(n²) per frame.

**Replacement:** bucket nodes into a uniform grid with a cell size equal to each force's cutoff, and compare each node only with its own and the 8 neighbouring cells.
- Because both forces are exactly zero beyond their cutoff, this finds the same interacting pairs, so it's exact, unlike Barnes–Hut, which approximates distant charge.
- Floating-point sums may differ in the last bits from the changed order. That's not visible.
- This matters for the Memory screen (LM-27), which draws the user-wide graph of up to 2,000 nodes.

### 7. "Which entity names are in this text?" (three implementations)

- `buildAgenda` → `justMentioned`: plain lower-case substring, O(V·T).
- `compileExtractionContext` → `exactIds`: normalized name substring, O(V·T), plus `normalizeName` re-run on every entity name every turn.
- graphloop `retrieve` → exact-name seeds: normalized substring, O(V·T), on every recall.

The same structure as #3 serves all three: a trie or Aho–Corasick automaton over the normalized names, built once per name set, giving O(T·L) per text. Each keeps its own normalization and boundary rule, since the three differ slightly today. Caching the normalized names saves the re-normalization even without the trie.

### 8. The user-wide graph view (`user_entities`, from LM-06)

**Today:** a view that groups all the user's entity rows on every read (28 ms for 3,000 rows), and `get_user_graph` returns up to 2,000 merged entities (508 KB) on every recall.

**Replacement:** a `user_entity_stats` table, kept current by the commit with upserts (`mentions += Δ`, `last_seen = greatest(...)`, description by its existing rules), and by LM-29's removal.
- Reads become an index scan of the top-k by mentions.
- This is the standard trade of write-time maintenance for read speed. It suits this app because commits are one per turn, while reads happen on every recall.

### 9. Recall's per-request rebuilds (`supabase/functions/retrieve-memory/handler.ts`, `rank`)

**Today:** `new SearchIndex()` then `sync(all entities)` on every request, plus `buildCommunities` (Louvain).
- The community summary is used only when no entity matches the query.

**Replacement:**
- Keep one `SearchIndex` per user in module scope. Edge isolates are reused while warm, so bound the cache with an LRU. Its `sync` already diffs by content hash, so a warm call re-indexes only changed entities.
- Compute communities lazily, only when seeds are empty, and cache them by a graph-version key, such as the max `last_seen` and row count.

## Order to adopt

1. **#5 (RLS init plans):** one migration, no app code, and it speeds every RLS-filtered query.
2. **#1 and #2, with agenda memoization:** pure Dart in two files. Verified identical, apart from the intended deterministic ties.
3. **#3 (highlighter):** a pure Dart replacement, verified identical.
4. **#4 (posting list):** a migration plus a commit change. It must land in order with LM-29's and LM-04's changes to `_commit_apply_turn`, never in parallel.
5. **#9, then #8:** server structure. #8 is the largest change and pays off as users accumulate notebooks.
6. **#6:** before the Memory screen (LM-27) ships.
