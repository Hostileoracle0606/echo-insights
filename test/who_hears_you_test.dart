// LM-53: the "Who hears you" screen, its first-mic-tap gate, and the privacy
// sheet entry.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/privacy/privacy_claims.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/privacy_screen_provider.dart';
import 'package:lumen/screens/dashboard/privacy_sheet.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/screens/privacy/who_hears_you_screen.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _Journal extends JournalNotifier {
  int starts = 0;

  @override
  JournalState build() => JournalState.empty();

  @override
  SessionStatus get status => SessionStatus.idle;

  @override
  List<ConversationTurn> get conversation => const [];

  @override
  Future<NotebookTransitionResult> startSession() async {
    starts += 1;
    return const NotebookTransitionResult.success();
  }
}

class _OpeningJournal extends _Journal {
  final entered = <({bool autoStart, bool offTheRecord, bool opened})>[];

  @override
  Future<NotebookTransitionResult> enterNotebook(
    String notebookId, {
    bool autoStart = false,
    bool offTheRecord = false,
    Future<bool> Function()? beforeOpening,
  }) async {
    // As a new notebook: Lumen opens it unless the gate says no.
    final opened = await beforeOpening!();
    entered.add((
      autoStart: autoStart,
      offTheRecord: offTheRecord,
      opened: opened,
    ));
    return const NotebookTransitionResult.success();
  }
}

/// [read] decides the profile read; [marked] counts the RPC calls.
class _Seen extends PrivacyScreenSeen {
  _Seen(this.read);
  final Future<bool> Function() read;
  int marked = 0;

  @override
  Future<bool> build() => read();

  @override
  Future<void> markSeen() async {
    marked += 1;
    state = const AsyncData(true);
  }
}

Future<void> _frames(WidgetTester tester, {int count = 30}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _pumpScreen(WidgetTester tester, WhoHearsYouScreen screen) async {
  tester.view
    ..physicalSize = const Size(402, 2400)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: LumenTheme.light(), home: screen),
  );
}

Future<(_Journal, _Seen)> _pumpJournal(
  WidgetTester tester,
  Future<bool> Function() read,
) async {
  final journal = _Journal();
  final seen = _Seen(read);
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        journalProvider.overrideWith(() => journal),
        privacyScreenSeenProvider.overrideWith(() => seen),
      ],
      child: MaterialApp(
        theme: LumenTheme.light(),
        home: const JournalScreen(),
      ),
    ),
  );
  await _frames(tester);
  return (journal, seen);
}

Future<void> _tapMic(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Microphone'));
  await _frames(tester);
}

void main() {
  group('the screen', () {
    testWidgets('names every party, with the "today" Google line', (t) async {
      await _pumpScreen(t, const WhoHearsYouScreen());
      for (final name in [
        'Google',
        'Amazon Web Services',
        'Supabase',
        'Us',
        'Anyone holding your phone',
      ]) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text(googleClaim(verified: false)), findsOneWidget);
      expect(find.text(googleClaim(verified: true)), findsNothing);
      expect(find.textContaining('train'), findsNothing);
      expect(find.text(supabaseClaim), findsOneWidget);
      expect(find.textContaining('could technically read it'), findsOneWidget);
      expect(find.text(usClaim), findsOneWidget);
      expect(find.text(phoneClaim), findsOneWidget);
      expect(find.text(exportClaim), findsOneWidget);
      expect(find.text(reachClaim), findsOneWidget);
      expect(find.textContaining('everyone'), findsNothing);
      // Not the first time: no start button.
      expect(find.byKey(const Key('privacyContinue')), findsNothing);
    });

    testWidgets('paid tier verified shows the "after billing" claim',
        (t) async {
      await _pumpScreen(t, const WhoHearsYouScreen(paidTierVerified: true));
      expect(find.text(googleClaim(verified: true)), findsOneWidget);
      expect(find.text(googleClaim(verified: false)), findsNothing);
      expect(
        find.textContaining('does not use them to train its models'),
        findsOneWidget,
      );
      expect(
        find.textContaining('abuse detection and legal reasons'),
        findsOneWidget,
      );
    });

    testWidgets('the encryption line needs verification', (t) async {
      await _pumpScreen(t, const WhoHearsYouScreen());
      expect(find.text(supabaseEncryptedClaim), findsNothing);
      await _pumpScreen(
        t,
        const WhoHearsYouScreen(supabaseEncryptionVerified: true),
      );
      expect(find.text(supabaseEncryptedClaim), findsOneWidget);
    });

    testWidgets('lines for unshipped controls stay hidden', (t) async {
      await _pumpScreen(t, const WhoHearsYouScreen(shipped: {}));
      for (final line in gatedClaims.values) {
        expect(find.text(line), findsNothing);
      }
    });

    testWidgets('the app shows every shipped control', (t) async {
      await _pumpScreen(t, const WhoHearsYouScreen());
      for (final line in gatedClaims.values) {
        expect(find.text(line), findsOneWidget);
      }
    });

    testWidgets('a shipped control shows only its own line', (t) async {
      await _pumpScreen(
        t,
        const WhoHearsYouScreen(shipped: {PrivacyFeature.forgetPerson}),
      );
      expect(
        find.text(gatedClaims[PrivacyFeature.forgetPerson]!),
        findsOneWidget,
      );
      expect(
          find.text(gatedClaims[PrivacyFeature.offTheRecord]!), findsNothing);
      expect(find.text(gatedClaims[PrivacyFeature.autoForget]!), findsNothing);
    });
  });

  group('first mic tap', () {
    testWidgets('shows once, starts on continue, then never again', (t) async {
      final (journal, seen) = await _pumpJournal(t, () async => false);

      await _tapMic(t);
      expect(find.byType(WhoHearsYouScreen), findsOneWidget);
      expect(journal.starts, 0);
      expect(seen.marked, 1);

      await t.tap(find.byKey(const Key('privacyContinue')));
      await _frames(t);
      expect(find.byType(WhoHearsYouScreen), findsNothing);
      expect(journal.starts, 1);

      await _tapMic(t);
      expect(find.byType(WhoHearsYouScreen), findsNothing);
      expect(journal.starts, 2);
      expect(seen.marked, 1);
    });

    testWidgets('closing it does not start, and still counts as seen',
        (t) async {
      final (journal, seen) = await _pumpJournal(t, () async => false);

      await _tapMic(t);
      await t.tap(find.byKey(const Key('privacyClose')));
      await _frames(t);
      expect(journal.starts, 0);
      expect(seen.marked, 1);

      await _tapMic(t);
      expect(find.byType(WhoHearsYouScreen), findsNothing);
      expect(journal.starts, 1);
    });

    testWidgets('already seen: no screen, starts at once', (t) async {
      final (journal, seen) = await _pumpJournal(t, () async => true);
      await _tapMic(t);
      expect(find.byType(WhoHearsYouScreen), findsNothing);
      expect(journal.starts, 1);
      expect(seen.marked, 0);
    });

    testWidgets('a second tap during the read stacks no second screen',
        (t) async {
      final read = Completer<bool>();
      final (journal, seen) = await _pumpJournal(t, () => read.future);
      await t.tap(find.bySemanticsLabel('Microphone'));
      await t.pump();
      await t.tap(find.bySemanticsLabel('Microphone'));
      await t.pump();
      read.complete(false);
      await _frames(t);
      expect(find.byType(WhoHearsYouScreen), findsOneWidget);
      expect(seen.marked, 1);

      await t.tap(find.byKey(const Key('privacyContinue')));
      await _frames(t);
      expect(find.byType(WhoHearsYouScreen), findsNothing);
      expect(journal.starts, 1);
    });

    testWidgets('a failed profile read does not block the mic', (t) async {
      final (journal, seen) =
          await _pumpJournal(t, () async => throw StateError('offline'));
      await _tapMic(t);
      expect(find.byType(WhoHearsYouScreen), findsNothing);
      expect(journal.starts, 1);
      expect(seen.marked, 0);
    });

    testWidgets('a read that never answers waits briefly, then starts',
        (t) async {
      final never = Completer<bool>();
      final (journal, _) = await _pumpJournal(t, () => never.future);
      await t.tap(find.bySemanticsLabel('Microphone'));
      await t.pump(const Duration(seconds: 3));
      await _frames(t);
      expect(find.byType(WhoHearsYouScreen), findsNothing);
      expect(journal.starts, 1);
    });
  });

  // A new notebook opens with Lumen by itself, so these go through the
  // ?start=true entry, not the mic.
  group('opening a new notebook', () {
    Future<_OpeningJournal> pumpOpening(
      WidgetTester tester,
      Future<bool> Function() read,
    ) async {
      final journal = _OpeningJournal();
      tester.view
        ..physicalSize = const Size(402, 874)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            journalProvider.overrideWith(() => journal),
            privacyScreenSeenProvider.overrideWith(() => _Seen(read)),
          ],
          child: MaterialApp(
            theme: LumenTheme.light(),
            home: const JournalScreen(
              notebookId: 'nb-1',
              autoStart: true,
              offTheRecord: true,
            ),
          ),
        ),
      );
      await _frames(tester);
      return journal;
    }

    testWidgets('closing the screen opens it quietly, still off the record',
        (t) async {
      final journal = await pumpOpening(t, () async => false);
      expect(find.byType(WhoHearsYouScreen), findsOneWidget);
      expect(journal.entered, isEmpty, reason: 'Lumen waits for the answer');

      await t.tap(find.byKey(const Key('privacyClose')));
      await _frames(t);
      final entry = journal.entered.single;
      expect(entry.opened, isFalse);
      expect(entry.offTheRecord, isTrue);
      expect(journal.starts, 0, reason: 'the gate is not asked twice');
    });

    testWidgets('continuing starts it, off the record', (t) async {
      final journal = await pumpOpening(t, () async => false);
      await t.tap(find.byKey(const Key('privacyContinue')));
      await _frames(t);
      final entry = journal.entered.single;
      expect(entry.autoStart, isTrue);
      expect(entry.opened, isTrue);
      expect(entry.offTheRecord, isTrue);
    });

    testWidgets('already seen: no screen, it starts', (t) async {
      final journal = await pumpOpening(t, () async => true);
      expect(find.byType(WhoHearsYouScreen), findsNothing);
      expect(journal.entered.single.opened, isTrue);
    });
  });

  testWidgets('the privacy sheet opens it, without a start button', (t) async {
    t.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: LumenTheme.light(),
          home: const Scaffold(body: PrivacySheet()),
        ),
      ),
    );
    await t.tap(find.byKey(const Key('whoHearsYouTile')));
    await _frames(t);
    expect(find.byType(WhoHearsYouScreen), findsOneWidget);
    expect(find.byKey(const Key('privacyContinue')), findsNothing);
  });
}
