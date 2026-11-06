// LM-49: "Forget [name]" on the note sheet, and its confirmation screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/journal/entity_note_sheet.dart';
import 'package:lumen/screens/journal/forget_entity_screen.dart';
import 'package:lumen/services/memory_control_service.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _Journal extends JournalNotifier {
  _Journal(this._seed, {this.fail = false});

  final JournalState _seed;
  final bool fail;
  final forgotten = <String>[];

  @override
  JournalState build() => _seed;

  @override
  Future<void> forgetEntity(String entityId) async {
    if (fail) throw Exception('boom');
    forgotten.add(entityId);
    state = state.copyWith(entities: {...state.entities}..remove(entityId));
  }
}

JournalState _seed() => JournalState.empty().copyWith(entities: {
      'priya': Entity(
        id: 'priya',
        name: 'Priya',
        type: EntityType.person,
        description: 'A friend from work.',
        metadata: const {},
        mentions: 2,
        firstSeen: DateTime(2026, 10, 20),
        lastSeen: DateTime(2026, 10, 22),
      ),
    });

const _counts = {
  'notebooks': 2,
  'relations': 3,
  'followUps': 1,
  'askedQuestions': 1,
  'cards': 1,
  'briefDeleted': true,
};

Future<({_Journal journal, List<String> rpcs})> _open(
  WidgetTester tester, {
  Map<String, Object?> preview = _counts,
  bool failForget = false,
  bool failPreview = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final journal = _Journal(_seed(), fail: failForget);
  final rpcs = <String>[];
  await tester.pumpWidget(ProviderScope(
    overrides: [
      journalProvider.overrideWith(() => journal),
      memoryControlServiceProvider
          .overrideWithValue(MemoryControlService.withRpc((fn, params) async {
        rpcs.add(fn);
        if (failPreview) throw Exception('offline');
        return preview;
      })),
    ],
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
  return (journal: journal, rpcs: rpcs);
}

Finder _labelled(String label) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    );

Future<void> _toConfirmation(WidgetTester tester) async {
  await tester.ensureVisible(_labelled('Forget Priya'));
  await tester.tap(_labelled('Forget Priya'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the note sheet offers Forget with a 44 pt target',
      (tester) async {
    await _open(tester);
    await tester.ensureVisible(_labelled('Forget Priya'));
    final size = tester.getSize(_labelled('Forget Priya'));
    expect(size.height, greaterThanOrEqualTo(44));
    expect(size.width, greaterThanOrEqualTo(44));
  });

  testWidgets('the confirmation lists what will be removed', (tester) async {
    final opened = await _open(tester);
    await _toConfirmation(tester);

    expect(find.byType(ForgetEntityScreen), findsOneWidget);
    expect(opened.rpcs, ['forget_entity_preview']);
    expect(find.textContaining('in 2 conversations'), findsOneWidget);
    expect(find.textContaining('3 connections'), findsOneWidget);
    expect(find.textContaining('2 questions'), findsOneWidget);
    expect(find.textContaining('1 conversation card'), findsOneWidget);
    expect(find.textContaining('briefing for next time'), findsOneWidget);
    expect(opened.journal.forgotten, isEmpty);
  });

  testWidgets('the brief line is left out when nothing will be deleted',
      (tester) async {
    await _open(tester, preview: {..._counts, 'briefDeleted': false});
    await _toConfirmation(tester);
    expect(find.textContaining('briefing for next time'), findsNothing);
  });

  testWidgets('Cancel forgets nothing and returns to the note', (tester) async {
    final opened = await _open(tester);
    await _toConfirmation(tester);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(opened.journal.forgotten, isEmpty);
    expect(find.byType(ForgetEntityScreen), findsNothing);
    expect(find.byType(EntityNoteSheet), findsOneWidget);
  });

  testWidgets('confirming forgets, closes both and says so', (tester) async {
    final opened = await _open(tester);
    await _toConfirmation(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Forget Priya'));
    await tester.pumpAndSettle();

    expect(opened.journal.forgotten, ['priya']);
    expect(find.byType(ForgetEntityScreen), findsNothing);
    expect(find.byType(EntityNoteSheet), findsNothing);
    expect(find.text('Forgot Priya'), findsOneWidget);
  });

  testWidgets('a failed forget stays on the screen and can be retried',
      (tester) async {
    final opened = await _open(tester, failForget: true);
    await _toConfirmation(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Forget Priya'));
    await tester.pumpAndSettle();

    expect(find.byType(ForgetEntityScreen), findsOneWidget);
    expect(find.text("Couldn't forget Priya. Try again."), findsOneWidget);
    expect(opened.journal.forgotten, isEmpty);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Forget Priya'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('if the preview cannot load, nothing can be forgotten',
      (tester) async {
    await _open(tester, failPreview: true);
    await _toConfirmation(tester);

    expect(find.textContaining("Couldn't check what would be removed"),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Forget Priya'), findsNothing);
  });
}
