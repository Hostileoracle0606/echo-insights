// LM-29: the note sheet's Edit and "Remove from memory" controls.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/entity_note_sheet.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _Journal extends JournalNotifier {
  _Journal(this._seed);

  final JournalState _seed;
  final edits = <(String, String)>[];
  final removed = <String>[];
  final undone = <String>[];
  final outcome = Completer<RemovalOutcome>();

  @override
  JournalState build() => _seed;

  @override
  Future<void> editEntityDescription(String entityId, String text) async {
    edits.add((entityId, text));
    final entity = state.entities[entityId]!;
    state = state.copyWith(entities: {
      ...state.entities,
      entityId: entity.copyWith(description: text, descriptionSource: 'user'),
    });
  }

  @override
  Future<RemovalOutcome> removeEntity(String entityId) {
    removed.add(entityId);
    state = state.copyWith(entities: {...state.entities}..remove(entityId));
    return outcome.future;
  }

  @override
  bool undoRemove(String entityId) {
    undone.add(entityId);
    return true;
  }
}

JournalState _seed({String source = 'extracted'}) =>
    JournalState.empty().copyWith(entities: {
      'priya': Entity(
        id: 'priya',
        name: 'Priya',
        type: EntityType.person,
        description: 'A friend from work.',
        descriptionSource: source,
        metadata: const {},
        mentions: 2,
        firstSeen: DateTime(2026, 10, 20),
        lastSeen: DateTime(2026, 10, 22),
      ),
    });

/// The sheet opened the way the app opens it: modally over a Scaffold, so
/// closing it and the snackbar behave as on device.
Future<_Journal> _open(WidgetTester tester, {String source = 'extracted'}) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final journal = _Journal(_seed(source: source));
  await tester.pumpWidget(ProviderScope(
    overrides: [journalProvider.overrideWith(() => journal)],
    child: MaterialApp(
      theme: LumenTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showEntityNoteSheet(context, 'priya'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return journal;
}

/// The control carrying this semantics label (the label is what VoiceOver
/// reads, so finding by it also checks it).
Finder _labelled(String label) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    );

void main() {
  testWidgets('Edit saves the text and shows "Edited by you"', (tester) async {
    final journal = await _open(tester);
    expect(find.text('Edited by you'), findsNothing);

    await tester.tap(_labelled('Edit description of Priya'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My closest friend at work.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(journal.edits, [('priya', 'My closest friend at work.')]);
    expect(find.text('My closest friend at work.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Edited by you'), findsOneWidget);
  });

  testWidgets('Cancel leaves the description as it was', (tester) async {
    final journal = await _open(tester);

    await tester.tap(_labelled('Edit description of Priya'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Something else.');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(journal.edits, isEmpty);
    expect(find.text('A friend from work.'), findsOneWidget);
  });

  testWidgets('a user-written description says so', (tester) async {
    await _open(tester, source: 'user');
    expect(find.text('Edited by you'), findsOneWidget);
  });

  testWidgets('remove asks first, and Cancel keeps the entity',
      (tester) async {
    final journal = await _open(tester);

    await tester.tap(_labelled('Remove Priya from memory'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining("Lumen will forget Priya and won't add them back."),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(journal.removed, isEmpty);
    expect(find.text('Priya'), findsOneWidget);
  });

  testWidgets('confirming removes, closes the sheet and offers Undo',
      (tester) async {
    final journal = await _open(tester);

    await tester.tap(_labelled('Remove Priya from memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(journal.removed, ['priya']);
    expect(find.byType(EntityNoteSheet), findsNothing);
    expect(find.text('Removed Priya'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(journal.undone, ['priya']);
  });

  testWidgets('the Undo snackbar leaves when the undo window ends',
      (tester) async {
    final journal = await _open(tester);

    await tester.tap(_labelled('Remove Priya from memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Removed Priya'), findsOneWidget);

    await tester.pump(removeUndoWindow);
    journal.outcome.complete(RemovalOutcome.removed);
    await tester.pumpAndSettle();
    expect(find.text('Removed Priya'), findsNothing);
  });

  testWidgets('a failed removal says so', (tester) async {
    final journal = await _open(tester);

    await tester.tap(_labelled('Remove Priya from memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    journal.outcome.complete(RemovalOutcome.failed);
    await tester.pumpAndSettle();

    expect(find.text("Couldn't remove Priya. Try again."), findsOneWidget);
  });

  testWidgets('every new control is at least 44 pt', (tester) async {
    await _open(tester);

    for (final label in [
      'Edit description of Priya',
      'Remove Priya from memory',
    ]) {
      final size = tester.getSize(_labelled(label));
      expect(size.height, greaterThanOrEqualTo(44), reason: label);
      expect(size.width, greaterThanOrEqualTo(44), reason: label);
    }

    await tester.tap(_labelled('Edit description of Priya'));
    await tester.pumpAndSettle();
    for (final text in ['Save', 'Cancel']) {
      final size = tester.getSize(find.widgetWithText(TextButton, text));
      expect(size.height, greaterThanOrEqualTo(44), reason: text);
    }
  });
}
