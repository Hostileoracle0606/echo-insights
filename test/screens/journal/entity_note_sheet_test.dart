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
  final JournalState _seed;

  _SeededJournal(this._seed);

  @override
  JournalState build() => _seed;
}

class _MutableSeededJournal extends JournalNotifier {
  JournalState _seed;

  _MutableSeededJournal(this._seed);

  @override
  JournalState build() => _seed;

  void replace(JournalState next) {
    _seed = next;
    state = next;
  }
}

Entity _entity(
  String id,
  String name,
  EntityType type, {
  int mentions = 1,
  String? description,
}) {
  return Entity(
    id: id,
    name: name,
    type: type,
    description: description,
    metadata: const {},
    mentions: mentions,
    firstSeen: DateTime(2026, 4, 20),
    lastSeen: DateTime(2026, 4, 26),
  );
}

Relation _rel(
  String id,
  String source,
  String target,
  String label, {
  DateTime? superseded,
}) {
  return Relation(
    id: id,
    source: source,
    target: target,
    label: label,
    metadata: const {},
    createdAt: DateTime(2026, 4, 26),
    supersededAt: superseded,
  );
}

JournalEntry _entry(String id, String text, DateTime createdAt) {
  return JournalEntry(
    id: id,
    text: text,
    createdAt: createdAt,
    entityIds: const ['maya'],
    relationIds: const [],
  );
}

Widget _host(JournalState seed, {String entityId = 'maya'}) {
  return ProviderScope(
    overrides: [journalProvider.overrideWith(() => _SeededJournal(seed))],
    child: MaterialApp(
      theme: LumenTheme.light(),
      home: Scaffold(body: EntityNoteSheet(entityId: entityId)),
    ),
  );
}

Widget _hostWithNotifier(
  _MutableSeededJournal journal, {
  String entityId = 'maya',
}) {
  return ProviderScope(
    overrides: [journalProvider.overrideWith(() => journal)],
    child: MaterialApp(
      theme: LumenTheme.light(),
      home: Scaffold(body: EntityNoteSheet(entityId: entityId)),
    ),
  );
}

void main() {
  testWidgets('header shows name and mention count; no back chevron at root',
      (tester) async {
    final seed = JournalState.empty().copyWith(
      entities: {
        'maya': _entity(
          'maya',
          'Maya',
          EntityType.person,
          mentions: 7,
          description: 'Maya keeps the Atlas work honest.',
        ),
      },
    );

    await tester.pumpWidget(_host(seed));
    await tester.pumpAndSettle();

    expect(find.text('Maya'), findsOneWidget);
    expect(find.textContaining('7 mentions'), findsOneWidget);
    expect(find.text('Maya keeps the Atlas work honest.'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.close), findsOneWidget);
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
        'r2': _rel(
          'r2',
          'maya',
          'ghost',
          'left',
          superseded: DateTime(2026, 4, 27),
        ),
      },
    );

    await tester.pumpWidget(_host(seed));
    await tester.pumpAndSettle();

    expect(find.text('CONNECTIONS'), findsOneWidget);
    expect(find.textContaining('works on'), findsOneWidget);
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
    expect(find.textContaining('involves'), findsOneWidget);
  });

  testWidgets('Recent mentions shows snippets newest-first, capped at 12',
      (tester) async {
    final entries = List.generate(
      12,
      (index) => _entry(
        'e$index',
        'Mention $index for Maya',
        DateTime(2026, 4, 26, 10, index),
      ),
    );
    final newest = _entry(
      'newest',
      '${List.filled(45, 'newest').join(' ')}\n\nvisible tail',
      DateTime(2026, 4, 26, 12),
    );
    final seed = JournalState.empty().copyWith(
      entities: {'maya': _entity('maya', 'Maya', EntityType.person)},
      entries: [...entries, newest],
    );

    await tester.pumpWidget(_host(seed));
    await tester.pumpAndSettle();

    expect(find.text('RECENT MENTIONS'), findsOneWidget);
    final mention11 = tester.getTopLeft(find.text('Mention 11 for Maya')).dy;
    final mention10 = tester.getTopLeft(find.text('Mention 10 for Maya')).dy;
    expect(mention11, lessThan(mention10));
    expect(find.text('Mention 0 for Maya'), findsNothing);
    expect(find.textContaining('\n'), findsNothing);
    expect(find.textContaining('\u2026'), findsOneWidget);
    expect(find.textContaining('visible tail'), findsNothing);
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
    expect(find.text('MENTIONED BY'), findsNothing);
    expect(find.text('RECENT MENTIONS'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'missing root entity shows unavailable: no chevron, close present',
      (tester) async {
    await tester.pumpWidget(_host(JournalState.empty(), entityId: 'gone'));
    await tester.pumpAndSettle();

    expect(find.text('Note unavailable'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

    expect(find.textContaining('3 mentions'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    expect(find.textContaining('7 mentions'), findsOneWidget);
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
    expect(find.text('Loop'), findsNWidgets(2));

    await tester.tap(find.text('Loop').last);
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.chevron_left), findsNothing);
  });

  testWidgets('relations with missing endpoints are skipped without crashing',
      (tester) async {
    final seed = JournalState.empty().copyWith(
      entities: {
        'maya': _entity('maya', 'Maya', EntityType.person),
        'atlas': _entity('atlas', 'Atlas', EntityType.project),
        'q3': _entity('q3', 'Q3 review', EntityType.event),
      },
      relations: {
        'valid-out': _rel('valid-out', 'maya', 'atlas', 'works_on'),
        'missing-target':
            _rel('missing-target', 'maya', 'missing-target', 'haunts'),
        'valid-in': _rel('valid-in', 'q3', 'maya', 'involves'),
        'missing-source':
            _rel('missing-source', 'missing-source', 'maya', 'found_by'),
      },
    );

    await tester.pumpWidget(_host(seed));
    await tester.pumpAndSettle();

    expect(find.text('CONNECTIONS'), findsOneWidget);
    expect(find.text('MENTIONED BY'), findsOneWidget);
    expect(find.text('Atlas'), findsOneWidget);
    expect(find.textContaining('works on'), findsOneWidget);
    expect(find.text('Q3 review'), findsOneWidget);
    expect(find.textContaining('involves'), findsOneWidget);
    expect(find.textContaining('haunts'), findsNothing);
    expect(find.textContaining('found by'), findsNothing);
    expect(find.text('missing-target'), findsNothing);
    expect(find.text('missing-source'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing deep entity keeps back chrome and returns to previous',
      (tester) async {
    final initial = JournalState.empty().copyWith(
      entities: {
        'maya': _entity('maya', 'Maya', EntityType.person, mentions: 7),
        'atlas': _entity('atlas', 'Atlas', EntityType.project, mentions: 3),
      },
      relations: {'r1': _rel('r1', 'maya', 'atlas', 'works_on')},
    );
    final journal = _MutableSeededJournal(initial);

    await tester.pumpWidget(_hostWithNotifier(journal));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Atlas'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 mentions'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);

    journal.replace(
      initial.copyWith(
        entities: {
          'maya': _entity('maya', 'Maya', EntityType.person, mentions: 7),
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Note unavailable'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    expect(find.text('Maya'), findsOneWidget);
    expect(find.textContaining('7 mentions'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
  });
}
