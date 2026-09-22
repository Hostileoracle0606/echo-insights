// Sidepane regression: the top-bar hamburger opens the graph drawer (entities
// grouped into sections by type), and tapping an entity opens its note sheet.
// Drives the real JournalScreen so the whole chain is covered: hamburger ->
// openDrawer -> drawer list -> tap -> closeDrawer -> showEntityNoteSheet.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/entity_note_sheet.dart';
import 'package:lumen/screens/journal/graph_drawer.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _SeededJournal extends JournalNotifier {
  _SeededJournal(this._seed);
  final JournalState _seed;
  @override
  JournalState build() => _seed;
}

JournalState _seedState() {
  final now = DateTime(2026, 4, 26, 14, 0);
  Entity e(String id, String name, EntityType type, int mentions) => Entity(
        id: id,
        name: name,
        type: type,
        metadata: const {},
        mentions: mentions,
        firstSeen: now,
        lastSeen: now,
      );
  return JournalState(
    entries: const [],
    entities: <String, Entity>{
      'maya': e('maya', 'Maya', EntityType.person, 7),
      'atlas': e('atlas', 'Atlas', EntityType.project, 9),
    },
    relations: const {},
    followUps: const [],
  );
}

void main() {
  testWidgets('hamburger opens the sidepane and an entity opens its note sheet',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          journalProvider.overrideWith(() => _SeededJournal(_seedState())),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: const JournalScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    // Closed: the drawer content isn't mounted; the hamburger is.
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.text('PEOPLE'), findsNothing);

    // Open the sidepane. GraphCanvas ticks forever, so hand-pump the drawer
    // animation instead of pumpAndSettle.
    await tester.tap(find.byIcon(Icons.menu));
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Sections + entities are listed (section headings are uppercased).
    expect(find.text('PEOPLE'), findsOneWidget);
    expect(find.text('PROJECTS'), findsOneWidget);
    // Entity names also appear as graph-canvas labels, so scope to the drawer.
    final mayaInDrawer = find.descendant(
      of: find.byType(GraphDrawer),
      matching: find.text('Maya'),
    );
    expect(mayaInDrawer, findsOneWidget);

    // Tap the entity -> drawer closes, the note sheet opens over the screen.
    await tester.tap(mayaInDrawer);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(EntityNoteSheet), findsOneWidget);

    // Unmount so the GraphCanvas ticker disposes before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}
