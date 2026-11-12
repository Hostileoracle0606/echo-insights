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
import 'package:lumen/security/app_lock.dart';
import 'package:lumen/security/app_lock_provider.dart';
import 'package:lumen/services/memory_control_service.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _Auth implements LockAuthenticator {
  _Auth({this.passes = true});
  bool passes;
  int prompts = 0;
  final reasons = <String>[];
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> authenticate(String reason) async {
    prompts += 1;
    reasons.add(reason);
    return passes;
  }
}

class _Journal extends JournalNotifier {
  _Journal(this._seed, {this.fail = false});

  final JournalState _seed;
  final bool fail;
  final forgotten = <String>[];
  final names = <String?>[];
  final erased = <bool>[];

  @override
  JournalState build() => _seed;

  @override
  Future<void> forgetEntity(String entityId,
      {String? name, bool eraseTranscripts = false}) async {
    if (fail) throw Exception('boom');
    forgotten.add(entityId);
    names.add(name);
    erased.add(eraseTranscripts);
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
  'transcriptPassages': 12,
};

Future<({_Journal journal, List<String> rpcs})> _open(
  WidgetTester tester, {
  Map<String, Object?> preview = _counts,
  bool failForget = false,
  bool failPreview = false,
  _Auth? auth,
}) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final journal = _Journal(_seed(), fail: failForget);
  final rpcs = <String>[];
  await tester.pumpWidget(ProviderScope(
    overrides: [
      journalProvider.overrideWith(() => journal),
      lockAuthenticatorProvider.overrideWithValue(auth ?? _Auth()),
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

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  // The confirmation is a lazy list: scroll until the control is built.
  await tester.scrollUntilVisible(finder, 120,
      scrollable: find
          .descendant(
              of: find.byType(ForgetEntityScreen),
              matching: find.byType(Scrollable))
          .first);
  await tester.pumpAndSettle();
  await tester.tap(finder);
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

  testWidgets('it says Lumen won\'t bring them up, and what stays for the user',
      (tester) async {
    await _open(tester);
    await _toConfirmation(tester);
    expect(find.textContaining('Priya on your map'), findsOneWidget);
    expect(find.textContaining("Lumen's memory of"), findsNothing);
    expect(find.textContaining("Lumen won't bring Priya up again"),
        findsOneWidget);
    expect(find.textContaining('a first name alone can slip'), findsOneWidget);
    expect(find.textContaining('keep your words for you to read'),
        findsOneWidget);
    expect(find.textContaining('may bring the name up'), findsNothing);
    expect(find.textContaining('Lumen can still read those'), findsNothing);
  });

  group('also erase them from my saved transcripts', () {
    Finder toggle() => find.widgetWithText(
        SwitchListTile, 'Also erase Priya from my saved transcripts');

    testWidgets('is off by default, and Forget then leaves transcripts alone',
        (tester) async {
      final opened = await _open(tester);
      await _toConfirmation(tester);

      await tester.ensureVisible(toggle());
      expect(tester.widget<SwitchListTile>(toggle()).value, isFalse);
      expect(find.textContaining("can't be undone"), findsOneWidget);
      expect(find.textContaining('12 passages'), findsOneWidget);

      await _tapVisible(tester, find.widgetWithText(FilledButton, 'Forget Priya'));
      await tester.pumpAndSettle();
      expect(opened.journal.forgotten, ['priya']);
      expect(opened.journal.erased, [false]);
    });

    testWidgets('on, Forget also erases', (tester) async {
      final auth = _Auth();
      final opened = await _open(tester, auth: auth);
      await _toConfirmation(tester);

      await tester.ensureVisible(toggle());
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle()).value, isTrue);

      await _tapVisible(tester, find.widgetWithText(FilledButton, 'Forget Priya'));
      await tester.pumpAndSettle();
      // A plain confirmation first: nothing is sent until it is accepted.
      expect(find.text('Erase Priya from your transcripts?'), findsOneWidget);
      expect(opened.journal.forgotten, isEmpty);
      await tester.tap(find.text('Erase and forget'));
      await tester.pumpAndSettle();
      expect(opened.journal.forgotten, ['priya']);
      expect(opened.journal.erased, [true]);
      // Behind the same re-auth as Forget; its reason names nobody.
      expect(auth.prompts, 1);
      expect(auth.reasons.single, contains('erase'));
      expect(auth.reasons.single, isNot(contains('Priya')));
    });

    testWidgets('on, cancelling the confirmation forgets nothing',
        (tester) async {
      final auth = _Auth();
      final opened = await _open(tester, auth: auth);
      await _toConfirmation(tester);

      await tester.ensureVisible(toggle());
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.widgetWithText(FilledButton, 'Forget Priya'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();

      expect(auth.prompts, 0);
      expect(opened.journal.forgotten, isEmpty);
      expect(find.byType(ForgetEntityScreen), findsOneWidget);
    });

    testWidgets('a failed re-auth with it on changes nothing', (tester) async {
      final auth = _Auth(passes: false);
      final opened = await _open(tester, auth: auth);
      await _toConfirmation(tester);

      await tester.ensureVisible(toggle());
      await tester.tap(toggle());
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.widgetWithText(FilledButton, 'Forget Priya'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Erase and forget'));
      await tester.pumpAndSettle();

      expect(auth.prompts, 1);
      expect(opened.journal.forgotten, isEmpty);
      expect(opened.journal.erased, isEmpty);
      expect(opened.rpcs, ['forget_entity_preview']);
      expect(find.byType(ForgetEntityScreen), findsOneWidget);
    });

    testWidgets('is not offered when no transcript names them', (tester) async {
      await _open(tester, preview: {..._counts, 'transcriptPassages': 0});
      await _toConfirmation(tester);
      expect(toggle(), findsNothing);
    });
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

    await _tapVisible(tester, find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(opened.journal.forgotten, isEmpty);
    expect(find.byType(ForgetEntityScreen), findsNothing);
    expect(find.byType(EntityNoteSheet), findsOneWidget);
  });

  testWidgets('confirming forgets, closes both and says so', (tester) async {
    final opened = await _open(tester);
    await _toConfirmation(tester);

    await _tapVisible(tester, find.widgetWithText(FilledButton, 'Forget Priya'));
    await tester.pumpAndSettle();

    expect(opened.journal.forgotten, ['priya']);
    expect(opened.journal.names, ['Priya'], reason: 'the name goes with it, for the redaction');
    expect(find.byType(ForgetEntityScreen), findsNothing);
    expect(find.byType(EntityNoteSheet), findsNothing);
    expect(find.text('Forgot Priya'), findsOneWidget);
  });

  testWidgets('a failed re-auth forgets nothing and can be retried',
      (tester) async {
    final auth = _Auth(passes: false);
    final opened = await _open(tester, auth: auth);
    await _toConfirmation(tester);

    await _tapVisible(tester, find.widgetWithText(FilledButton, 'Forget Priya'));
    await tester.pumpAndSettle();

    expect(auth.prompts, 1);
    expect(opened.journal.forgotten, isEmpty);
    expect(find.byType(ForgetEntityScreen), findsOneWidget);

    auth.passes = true;
    await _tapVisible(tester, find.widgetWithText(FilledButton, 'Forget Priya'));
    await tester.pumpAndSettle();
    expect(opened.journal.forgotten, ['priya']);
  });

  testWidgets('a failed forget stays on the screen and can be retried',
      (tester) async {
    final opened = await _open(tester, failForget: true);
    await _toConfirmation(tester);

    await _tapVisible(tester, find.widgetWithText(FilledButton, 'Forget Priya'));
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
