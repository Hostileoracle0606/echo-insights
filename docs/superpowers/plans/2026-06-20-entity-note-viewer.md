# Entity Note Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the graph's plain entity bottom sheet with a paper-themed, navigable `EntityNoteSheet` — an Obsidian-like reading surface with tappable relation wikilinks, backlinks, recent mentions, and an internal back stack.

**Architecture:** A `DraggableScrollableSheet` presented via `showModalBottomSheet(isScrollControlled: true)`. The sheet is a `ConsumerStatefulWidget` that reads `JournalState` from `journalProvider` and owns an in-memory navigation history (`List<String>` of entity ids); tapping a wikilink swaps content in place by pushing onto that history, a back chevron pops it. All rendering is native widgets from structured state — no markdown.

**Tech Stack:** Flutter 3.41, Riverpod (`NotifierProvider`), the Phase-2 token layer (`LumenColors`, `LumenText`).

**Spec:** [docs/superpowers/specs/2026-06-20-entity-note-viewer-design.md](../specs/2026-06-20-entity-note-viewer-design.md)

---

## File Structure

| File | Responsibility |
|---|---|
| Create `lib/logic/relative_time.dart` | Pure `relativeTime(DateTime, {DateTime? now})` → "just now / 5m ago / 2h ago / 3d ago / Apr 26". |
| Create `lib/logic/snippet.dart` | Pure `snippet(String, {int max = 140})` → one-line, word-boundary-truncated entry preview with an ellipsis. |
| Create `lib/screens/journal/wikilink.dart` | `WikiLink` — an entity name as ink text with an amber underline; tappable when `onTap != null`, plain text when null (self-links). |
| Create `lib/screens/journal/entity_note_sheet.dart` | `EntityNoteSheet(entityId)` + `showEntityNoteSheet(context, entityId)` helper. Owns history, reads `journalProvider`, builds header + description + Connections + Mentioned-by + Recent mentions inside a `DraggableScrollableSheet`. |
| Modify `lib/screens/journal/graph_canvas.dart` | `_handleTap` presents `showEntityNoteSheet`; delete the dark `_EntitySheet`. |
| Create tests | `test/relative_time_test.dart`, `test/snippet_test.dart`, `test/screens/journal/wikilink_test.dart`, `test/screens/journal/entity_note_sheet_test.dart`. |

Dependencies: Task 3 uses Tasks 1–2; Task 4 modifies Task 3; Task 5 uses Task 3's helper.

> Verification convention: run `flutter analyze lib/ test/` (scoped — the repo has one pre-existing unrelated `info` lint in `tool/ui_preview_app.dart` that a bare `flutter analyze` would also report).

---

### Task 1: pure logic helpers (`relativeTime` + `snippet`)

**Files:**
- Create: `lib/logic/relative_time.dart`
- Create: `lib/logic/snippet.dart`
- Test: `test/relative_time_test.dart`
- Test: `test/snippet_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/relative_time_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/relative_time.dart';

void main() {
  final now = DateTime(2026, 4, 28, 12, 0);

  test('formats sub-minute, minutes, hours, days', () {
    expect(relativeTime(now.subtract(const Duration(seconds: 30)), now: now), 'just now');
    expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now), '5m ago');
    expect(relativeTime(now.subtract(const Duration(hours: 2)), now: now), '2h ago');
    expect(relativeTime(now.subtract(const Duration(days: 3)), now: now), '3d ago');
  });

  test('falls back to "Mon D" beyond a week', () {
    expect(relativeTime(DateTime(2026, 4, 18), now: now), 'Apr 18');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/relative_time_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:lumen/logic/relative_time.dart'`.

- [ ] **Step 3: Write the implementation**

```dart
// lib/logic/relative_time.dart
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Human-friendly elapsed time, mirroring the web app's formatRelative.
/// `now` is injectable for deterministic tests.
String relativeTime(DateTime date, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final diff = ref.difference(date);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${_months[date.month - 1]} ${date.day}';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/relative_time_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/logic/relative_time.dart test/relative_time_test.dart
git commit -m "feat(notes): add relativeTime helper"
```

- [ ] **Step 6: Write the failing snippet test**

```dart
// test/snippet_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/snippet.dart';

void main() {
  test('short text is returned unchanged', () {
    expect(snippet('Maya flagged the slip.'), 'Maya flagged the slip.');
  });

  test('long text is truncated to max with an ellipsis, on a word boundary', () {
    final long = 'word ' * 60; // 300 chars
    final out = snippet(long, max: 140);
    expect(out.length, lessThanOrEqualTo(141)); // 140 cap + the … char
    expect(out.endsWith('…'), isTrue);
    expect(out, isNot(contains('  '))); // trimmed before the ellipsis
  });
}
```

- [ ] **Step 7: Run test to verify it fails**

Run: `flutter test test/snippet_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:lumen/logic/snippet.dart'`.

- [ ] **Step 8: Write the implementation**

```dart
// lib/logic/snippet.dart
/// One-line preview of an entry's text, capped at [max] characters.
/// Mirrors the web export's snippet(): cut on a word boundary near the cap
/// and append an ellipsis. Returns the input unchanged when already short.
String snippet(String text, {int max = 140}) {
  final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.length <= max) return clean;
  final cut = clean.substring(0, max);
  final lastSpace = cut.lastIndexOf(' ');
  final base = lastSpace > 0 ? cut.substring(0, lastSpace) : cut;
  return '${base.trimRight()}…';
}
```

- [ ] **Step 9: Run test to verify it passes**

Run: `flutter test test/snippet_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 10: Commit**

```bash
git add lib/logic/snippet.dart test/snippet_test.dart
git commit -m "feat(notes): add snippet helper for entry previews"
```

---

### Task 2: `WikiLink` widget

**Files:**
- Create: `lib/screens/journal/wikilink.dart`
- Test: `test/screens/journal/wikilink_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/screens/journal/wikilink_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/screens/journal/wikilink.dart';
import 'package:lumen/theme/lumen_theme.dart';

Widget _host(Widget child) =>
    MaterialApp(theme: LumenTheme.light(), home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('tappable wikilink fires onTap with its id', (tester) async {
    String? tapped;
    await tester.pumpWidget(_host(
      WikiLink(entityId: 'atlas', label: 'Atlas', onTap: () => tapped = 'atlas'),
    ));
    await tester.tap(find.text('Atlas'));
    expect(tapped, 'atlas');
  });

  testWidgets('null onTap renders plain, non-tappable, un-underlined text',
      (tester) async {
    await tester.pumpWidget(_host(
      const WikiLink(entityId: 'maya', label: 'Maya', onTap: null),
    ));
    expect(find.text('Maya'), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);
    final text = tester.widget<Text>(find.text('Maya'));
    expect(text.style?.decoration, TextDecoration.none);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/screens/journal/wikilink_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:lumen/screens/journal/wikilink.dart'`.

- [ ] **Step 3: Write the implementation**

```dart
// lib/screens/journal/wikilink.dart
import 'package:flutter/material.dart';
import 'package:lumen/theme/lumen_colors.dart';

/// An entity reference rendered as ink text with an amber underline — the
/// in-app form of an Obsidian `[[wikilink]]`. Tappable when [onTap] is set;
/// a null [onTap] renders plain text (used for self-links).
class WikiLink extends StatelessWidget {
  final String entityId;
  final String label;
  final VoidCallback? onTap;

  const WikiLink({
    super.key,
    required this.entityId,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    // Non-tappable (self-link): plain ink text, no underline — it must not
    // look like a link the user can follow.
    if (onTap == null) {
      return Text(
        label,
        style: TextStyle(
          fontSize: 14,
          height: 1.4,
          color: colors.ink,
          decoration: TextDecoration.none,
        ),
      );
    }
    // Tappable: ink text with the amber underline that signals a wikilink.
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          height: 1.4,
          color: colors.ink,
          decoration: TextDecoration.underline,
          decorationColor: colors.amber,
          decorationThickness: 1.5,
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/screens/journal/wikilink_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/screens/journal/wikilink.dart test/screens/journal/wikilink_test.dart
git commit -m "feat(notes): add WikiLink widget"
```

---

### Task 3: `EntityNoteSheet` — content + helper (relations not yet tappable)

**Files:**
- Create: `lib/screens/journal/entity_note_sheet.dart`
- Test: `test/screens/journal/entity_note_sheet_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// test/screens/journal/entity_note_sheet_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/entity_note_sheet.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _SeededJournal extends JournalNotifier {
  _SeededJournal(this._seed);
  final JournalState _seed;
  @override
  JournalState build() => _seed;
}

Entity _entity(String id, String name, EntityType type,
        {int mentions = 1, String? description}) =>
    Entity(
      id: id, name: name, type: type, metadata: const {},
      mentions: mentions,
      firstSeen: DateTime(2026, 4, 20), lastSeen: DateTime(2026, 4, 26),
      description: description,
    );

Relation _rel(String id, String src, String tgt, String label,
        {DateTime? superseded}) =>
    Relation(
      id: id, source: src, target: tgt, label: label, metadata: const {},
      createdAt: DateTime(2026, 4, 26), supersededAt: superseded,
    );

Widget _host(JournalState seed, {String entityId = 'maya'}) => ProviderScope(
      overrides: [journalProvider.overrideWith(() => _SeededJournal(seed))],
      child: MaterialApp(
        theme: LumenTheme.light(),
        home: Scaffold(body: EntityNoteSheet(entityId: entityId)),
      ),
    );

void main() {
  testWidgets('header shows name and mention count; no back chevron at root',
      (tester) async {
    final seed = JournalState.empty().copyWith(
      entities: {'maya': _entity('maya', 'Maya', EntityType.person, mentions: 7)},
    );
    await tester.pumpWidget(_host(seed));
    await tester.pumpAndSettle();
    expect(find.text('Maya'), findsOneWidget);
    expect(find.textContaining('7 mentions'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
  });

  testWidgets('Connections lists active outbound, excludes superseded',
      (tester) async {
    final seed = JournalState.empty().copyWith(
      entities: {
        'maya': _entity('maya', 'Maya', EntityType.person),
        'atlas': _entity('atlas', 'Atlas', EntityType.project),
        'ghost': _entity('ghost', 'Ghost', EntityType.other),
      },
      relations: {
        'r1': _rel('r1', 'maya', 'atlas', 'works_on'),
        'r2': _rel('r2', 'maya', 'ghost', 'left', superseded: DateTime(2026, 4, 27)),
      },
    );
    await tester.pumpWidget(_host(seed));
    await tester.pumpAndSettle();
    expect(find.text('CONNECTIONS'), findsOneWidget);
    expect(find.text('Atlas'), findsOneWidget);
    expect(find.text('Ghost'), findsNothing);
  });

  testWidgets('Mentioned by lists active inbound', (tester) async {
    final seed = JournalState.empty().copyWith(
      entities: {
        'maya': _entity('maya', 'Maya', EntityType.person),
        'q3': _entity('q3', 'Q3 review', EntityType.event),
      },
      relations: {'r1': _rel('r1', 'q3', 'maya', 'involves')},
    );
    await tester.pumpWidget(_host(seed));
    await tester.pumpAndSettle();
    expect(find.text('MENTIONED BY'), findsOneWidget);
    expect(find.text('Q3 review'), findsOneWidget);
  });

  testWidgets('Recent mentions shows entry snippets', (tester) async {
    final seed = JournalState.empty().copyWith(
      entities: {'maya': _entity('maya', 'Maya', EntityType.person)},
      entries: [
        JournalEntry(
          id: 'e1', text: 'Maya flagged the Atlas slip.',
          createdAt: DateTime(2026, 4, 26, 14, 32),
          entityIds: const ['maya'], relationIds: const [],
        ),
      ],
    );
    await tester.pumpWidget(_host(seed));
    await tester.pumpAndSettle();
    expect(find.text('RECENT MENTIONS'), findsOneWidget);
    expect(find.textContaining('Maya flagged'), findsOneWidget);
  });

  testWidgets('empty entity renders header only without throwing',
      (tester) async {
    final seed = JournalState.empty().copyWith(
      entities: {'lonely': _entity('lonely', 'Lonely', EntityType.concept)},
    );
    await tester.pumpWidget(_host(seed, entityId: 'lonely'));
    await tester.pumpAndSettle();
    expect(find.text('Lonely'), findsOneWidget);
    expect(find.text('CONNECTIONS'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing root entity shows unavailable: no chevron, close present',
      (tester) async {
    final seed = JournalState.empty(); // no entities at all
    await tester.pumpWidget(_host(seed, entityId: 'gone'));
    await tester.pumpAndSettle();
    expect(find.text('Note unavailable'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing); // root → no back
    expect(find.byIcon(Icons.close), findsOneWidget); // close always available
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/screens/journal/entity_note_sheet_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:lumen/screens/journal/entity_note_sheet.dart'`.

- [ ] **Step 3: Write the implementation**

```dart
// lib/screens/journal/entity_note_sheet.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumen/logic/relative_time.dart';
import 'package:lumen/logic/snippet.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/wikilink.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_text.dart';

/// Presents the entity note as a draggable, scroll-controlled modal sheet.
/// `isScrollControlled: true` is required so the sheet can expand past
/// ~half-screen; `useSafeArea` keeps the expanded sheet clear of the island.
Future<void> showEntityNoteSheet(BuildContext context, String entityId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => EntityNoteSheet(entityId: entityId),
  );
}

class EntityNoteSheet extends ConsumerStatefulWidget {
  final String entityId;
  const EntityNoteSheet({super.key, required this.entityId});

  @override
  ConsumerState<EntityNoteSheet> createState() => _EntityNoteSheetState();
}

class _EntityNoteSheetState extends ConsumerState<EntityNoteSheet> {
  late final List<String> _history = [widget.entityId];

  String get _currentId => _history.last;
  bool get _canGoBack => _history.length > 1;

  void _back() {
    if (_canGoBack) setState(() => _history.removeLast());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(journalProvider);
    final colors = context.lumenColors;
    final entity = state.entities[_currentId];

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: entity == null
              ? _unavailable(scrollController, colors)
              : _note(scrollController, state, entity, colors),
        );
      },
    );
  }

  Widget _header(LumenColors colors) {
    return Row(
      children: [
        if (_canGoBack)
          IconButton(
            icon: const Icon(Icons.chevron_left),
            color: colors.mutedForeground,
            onPressed: _back,
          )
        else
          const SizedBox(width: 8),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close),
          color: colors.mutedForeground,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }

  Widget _unavailable(ScrollController controller, LumenColors colors) {
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _header(colors),
        const SizedBox(height: 24),
        Center(
          child: Text('Note unavailable',
              style: TextStyle(color: colors.mutedForeground)),
        ),
      ],
    );
  }

  Widget _note(ScrollController controller, JournalState state, Entity entity,
      LumenColors colors) {
    final outbound = state.relations.values
        .where((r) =>
            r.isActive &&
            r.source == entity.id &&
            state.entities[r.target] != null)
        .toList();
    final inbound = state.relations.values
        .where((r) =>
            r.isActive &&
            r.target == entity.id &&
            r.source != entity.id &&
            state.entities[r.source] != null)
        .toList();
    final mentions = state.entries
        .where((e) => e.entityIds.contains(entity.id))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final recent = mentions.take(12).toList();

    final dotColor = LumenColors.entityColors[entity.type] ??
        LumenColors.entityColors[EntityType.other]!;

    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        _header(colors),
        Row(children: [
          Container(
            width: 8, height: 8,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          Text(entity.type.name.toUpperCase(),
              style: LumenText.eyebrow(colors.mutedForeground)),
        ]),
        const SizedBox(height: 4),
        Text(entity.name, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(_metaLine(entity),
            style: TextStyle(fontSize: 12, color: colors.mutedForeground)),
        if (entity.description?.isNotEmpty == true) ...[
          const SizedBox(height: 14),
          Text(entity.description!,
              style: TextStyle(fontSize: 15, height: 1.5, color: colors.ink)),
        ],
        if (outbound.isNotEmpty) ...[
          _sectionLabel('Connections', colors),
          for (final r in outbound)
            _connectionRow(state, r, colors, outbound: true),
        ],
        if (inbound.isNotEmpty) ...[
          _sectionLabel('Mentioned by', colors),
          for (final r in inbound)
            _connectionRow(state, r, colors, outbound: false),
        ],
        if (recent.isNotEmpty) ...[
          _sectionLabel('Recent mentions', colors),
          for (final e in recent) _mentionRow(e, colors),
        ],
      ],
    );
  }

  String _metaLine(Entity entity) {
    final count =
        '${entity.mentions} ${entity.mentions == 1 ? "mention" : "mentions"}';
    return '$count · last ${relativeTime(entity.lastSeen)}';
  }

  Widget _sectionLabel(String text, LumenColors colors) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Text(text.toUpperCase(),
          style: LumenText.eyebrow(colors.mutedForeground)),
    );
  }

  Widget _connectionRow(JournalState state, Relation r, LumenColors colors,
      {required bool outbound}) {
    final label = r.label.replaceAll('_', ' ');
    final relatedId = outbound ? r.target : r.source;
    final related = state.entities[relatedId]!;
    final link = WikiLink(entityId: related.id, label: related.name, onTap: null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: outbound
            ? [
                Text('$label → ',
                    style: TextStyle(fontSize: 14, color: colors.mutedForeground)),
                link,
              ]
            : [
                link,
                Text(' — $label',
                    style: TextStyle(fontSize: 14, color: colors.mutedForeground)),
              ],
      ),
    );
  }

  Widget _mentionRow(JournalEntry e, LumenColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(relativeTime(e.createdAt),
              style: TextStyle(fontSize: 12, color: colors.mutedForeground)),
          const SizedBox(height: 3),
          Text(snippet(e.text),
              style: TextStyle(fontSize: 13, height: 1.4, color: colors.ink)),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/screens/journal/entity_note_sheet_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/screens/journal/entity_note_sheet.dart test/screens/journal/entity_note_sheet_test.dart
git commit -m "feat(notes): EntityNoteSheet content + showEntityNoteSheet helper"
```

---

### Task 4: `EntityNoteSheet` — wikilink traversal + self-relation rule

**Files:**
- Modify: `lib/screens/journal/entity_note_sheet.dart`
- Test: `test/screens/journal/entity_note_sheet_test.dart` (append two tests)

- [ ] **Step 1: Append the failing tests**

Add these two tests inside the existing `main()` in `test/screens/journal/entity_note_sheet_test.dart` (the helpers `_SeededJournal`, `_entity`, `_rel`, `_host` are already defined above):

```dart
  testWidgets('tapping a Connections wikilink swaps content and reveals back',
      (tester) async {
    final seed = JournalState.empty().copyWith(
      entities: {
        'maya': _entity('maya', 'Maya', EntityType.person, mentions: 7),
        'atlas': _entity('atlas', 'Atlas', EntityType.project, mentions: 3),
      },
      relations: {'r1': _rel('r1', 'maya', 'atlas', 'works_on')},
    );
    await tester.pumpWidget(_host(seed));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_left), findsNothing);

    await tester.tap(find.text('Atlas'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 mentions'), findsOneWidget); // Atlas now shown
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.textContaining('7 mentions'), findsOneWidget); // back to Maya
  });

  testWidgets('self-relation shows once under Connections, non-tappable',
      (tester) async {
    final seed = JournalState.empty().copyWith(
      entities: {'loop': _entity('loop', 'Loop', EntityType.concept)},
      relations: {'r1': _rel('r1', 'loop', 'loop', 'relates_to')},
    );
    await tester.pumpWidget(_host(seed, entityId: 'loop'));
    await tester.pumpAndSettle();
    expect(find.text('CONNECTIONS'), findsOneWidget);
    expect(find.text('MENTIONED BY'), findsNothing);
    // 'Loop' appears in the header and once in Connections.
    expect(find.text('Loop'), findsNWidgets(2));
    // The Connections 'Loop' is non-tappable: tapping it does not navigate.
    await tester.tap(find.text('Loop').last);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.chevron_left), findsNothing);
  });
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `flutter test test/screens/journal/entity_note_sheet_test.dart`
Expected: the traversal test FAILS (tapping "Atlas" does nothing — `onTap` is null, so no swap and no chevron). The self-relation test passes already (links are non-tappable), but the traversal regression is the red signal.

- [ ] **Step 3: Wire the wikilink taps**

In `lib/screens/journal/entity_note_sheet.dart`, add an `_open` method next to `_back`:

```dart
  void _open(String id) {
    if (id == _currentId) return; // ignore re-tapping the current note
    setState(() => _history.add(id));
  }
```

Then in `_connectionRow`, make non-self links tappable. Replace this line:

```dart
    final link = WikiLink(entityId: related.id, label: related.name, onTap: null);
```

with:

```dart
    final isSelf = r.source == r.target;
    final link = WikiLink(
      entityId: related.id,
      label: related.name,
      onTap: isSelf ? null : () => _open(related.id),
    );
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/screens/journal/entity_note_sheet_test.dart`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/screens/journal/entity_note_sheet.dart test/screens/journal/entity_note_sheet_test.dart
git commit -m "feat(notes): wikilink traversal with back stack; self-links non-tappable"
```

---

### Task 5: Wire into the graph; remove the old sheet

**Files:**
- Modify: `lib/screens/journal/graph_canvas.dart` (`_handleTap` ~line 131; `_EntitySheet` class ~line 170)

- [ ] **Step 1: Replace the node-tap handler**

In `lib/screens/journal/graph_canvas.dart`, add the import near the other local imports:

```dart
import 'entity_note_sheet.dart';
```

Then in `_handleTap`, replace the `showModalBottomSheet(...)` call:

```dart
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: const Color(0xFF191B20),
      builder: (context) => _EntitySheet(entity: hit!.entity),
    );
```

with:

```dart
    showEntityNoteSheet(context, hit.entity.id);
```

- [ ] **Step 2: Delete the obsolete `_EntitySheet`**

Remove the entire `class _EntitySheet extends StatelessWidget { … }` block (starts ~line 170). `NodeGlyph` (used only inside `_EntitySheet`) can stay imported — `node_glyph.dart` is still used by the painter via `colorForEntityType` at `graph_canvas.dart:253`, so the import does not go unused.

- [ ] **Step 3: Analyze + run the full suite**

Run: `flutter analyze lib/ test/ && flutter test`
Expected: `No issues found!` and all tests pass (existing suite + the 4 new test files: relative_time, snippet, wikilink, entity_note_sheet). If the analyzer reports `unused_import` for `entity.dart` in `graph_canvas.dart`, leave it — `Entity`/`EntityType` are still referenced by the painter and node model.

- [ ] **Step 4: Manual verification**

Run: `flutter run` on the iPhone 17 simulator, open a notebook with entities, tap a node.
Expected: a paper-colored bottom sheet (not the old dark `#191B20`) with the entity name in Fraunces, a type eyebrow with a colored dot, Connections/Mentioned-by with amber-underlined names, and Recent mentions. Tapping a connection swaps the sheet to that entity and shows a back chevron; the chevron returns. Swipe-down dismisses.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/journal/graph_canvas.dart
git commit -m "feat(notes): open EntityNoteSheet from graph node taps; drop dark _EntitySheet"
```

---

## Self-Review

**Spec coverage:**
- Entry via node tap + `showModalBottomSheet` → Task 5 ✓
- In-place wikilink traversal with internal history + back chevron (hidden at root) → Tasks 3 (history/chevron) + 4 (push/pop wiring) ✓
- Dismiss (swipe/scrim/`×`) → `showModalBottomSheet` + close button (Task 3) ✓
- Scroll plumbing: `isScrollControlled: true`, `useSafeArea`, `DraggableScrollableSheet` controller into the `ListView`, sizing `0.55/0.4/0.92` → Task 3 ✓
- Header (chevron+close, eyebrow+`entityColors` dot, Fraunces name, meta) → Task 3 ✓
- Description (omitted when empty) → Task 3 ✓
- Connections (active outbound, self included, missing target skipped) → Tasks 3/4 ✓
- Mentioned-by (active inbound, `source != entityId` guard) → Task 3 ✓
- Recent mentions (entries containing id, newest first, cap 12, read-only, **word-boundary `snippet()` truncation**) → Task 1 (`snippet` + truncation test) + Task 3 (`_mentionRow` uses it) ✓
- Self-link is visually plain (no amber underline) as well as non-tappable → Task 2 (`onTap == null` branch + decoration test) ✓
- "Note unavailable" for a missing root entity (no chevron, close present) → Task 3 (dedicated test) ✓
- Self-relation: once under Connections only, non-tappable → Task 4 (test + `isSelf` guard) ✓
- Render-from-`JournalState`, read-only, no markdown → all tasks ✓
- Token-based (LumenColors/LumenText, replaces dark `#191B20`) → Tasks 3/5 ✓
- Test seam = seeded `JournalNotifier` via `overrideWith` → Task 3 test harness ✓
- "Note unavailable" with same chrome rules → Task 3 (`_unavailable` uses `_header`, chevron hidden at depth 1) ✓
- Out of scope (no Notes mode/MOC/daily notes, no editing, inline-description linkification deferred) → not built ✓

**Placeholder scan:** none — every code step shows complete code; the one conditional ("if analyzer reports unused_import…") is a verified-safe note, not a TODO.

**Type consistency:** `relativeTime(DateTime, {DateTime? now})` and `snippet(String, {int max})` (Task 1) match their calls in Task 3. `WikiLink({entityId, label, onTap})` (Task 2) matches usage in Tasks 3/4. `showEntityNoteSheet(BuildContext, String)` (Task 3) matches the call in Task 5. `EntityNoteSheet(entityId:)` consistent across tasks/tests. `_open`/`_back`/`_canGoBack`/`_currentId`/`_history` names consistent. Model fields (`Entity.lastSeen/mentions/type/description`, `Relation.source/target/label/isActive`, `JournalEntry.text/createdAt/entityIds`, `JournalState.entities/relations/entries` + `empty()`/`copyWith`) verified against `lib/models/`.
