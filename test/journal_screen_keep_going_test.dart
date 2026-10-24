// LM-16: keeping going from the closing card. Talk (?start=true) and Type
// (?compose=true) open a notebook that already has a conversation, which
// enterNotebook opens quietly, so the screen starts the session itself; Type
// then opens the composer (typing needs a session to send into).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/composer.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _QuietJournal extends JournalNotifier {
  _QuietJournal({this.afterEntry = SessionStatus.idle});

  /// The status enterNotebook leaves: idle for a notebook that opens
  /// quietly, connecting for a new one that opens with Lumen.
  final SessionStatus afterEntry;
  SessionStatus current = SessionStatus.idle;
  int starts = 0;
  int pauses = 0;
  bool? enteredWithAutoStart;

  @override
  JournalState build() => JournalState.empty();

  @override
  SessionStatus get status => current;

  @override
  Future<NotebookTransitionResult> enterNotebook(
    String notebookId, {
    bool autoStart = false,
  }) async {
    enteredWithAutoStart = autoStart;
    current = afterEntry;
    state = state.copyWith();
    return const NotebookTransitionResult.success();
  }

  @override
  Future<NotebookTransitionResult> startSession() async {
    starts += 1;
    current = SessionStatus.live;
    state = state.copyWith();
    return const NotebookTransitionResult.success();
  }

  @override
  Future<void> pauseMic() async {
    pauses += 1;
    if (current == SessionStatus.live) current = SessionStatus.paused;
    state = state.copyWith();
  }
}

Future<_QuietJournal> _pump(
  WidgetTester tester,
  JournalScreen screen, {
  SessionStatus afterEntry = SessionStatus.idle,
}) async {
  final journal = _QuietJournal(afterEntry: afterEntry);
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [journalProvider.overrideWith(() => journal)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: LumenTheme.light(),
        home: screen,
      ),
    ),
  );
  // The graph's force simulation ticks forever: step frames.
  for (var i = 0; i < 45; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return journal;
}

void main() {
  testWidgets('?compose=true starts the session and opens the composer',
      (tester) async {
    final journal = await _pump(
      tester,
      const JournalScreen(notebookId: 'nb-1', compose: true),
    );
    expect(journal.starts, 1);
    expect(journal.pauses, 1, reason: 'typing pauses the mic');
    expect(find.byType(Composer), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('?start=true starts a session the notebook opened quietly',
      (tester) async {
    final journal = await _pump(
      tester,
      const JournalScreen(notebookId: 'nb-1', autoStart: true),
    );
    expect(journal.enteredWithAutoStart, isTrue);
    expect(journal.starts, 1);
    expect(find.byType(Composer), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('?start=true leaves a session Lumen is already opening alone',
      (tester) async {
    final journal = await _pump(
      tester,
      const JournalScreen(notebookId: 'nb-1', autoStart: true),
      afterEntry: SessionStatus.connecting,
    );
    expect(journal.starts, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a plain open starts nothing', (tester) async {
    final journal = await _pump(
      tester,
      const JournalScreen(notebookId: 'nb-1'),
    );
    expect(journal.starts, 0);
    expect(find.byType(Composer), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
