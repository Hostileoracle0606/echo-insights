// Stitch regression: the pill's View toggle should turn the screen over to
// the transcript page (graph behind it), and back again. The toggle is one
// button whose icon names the view it switches to: article -> transcript,
// hub -> graph. Exercises the real JournalScreen (not a composed stand-in) so
// the wiring — view button -> page transition -> transcriptRowsProvider ->
// turns — is covered.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/graph_canvas.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/screens/journal/transcript_page.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _SeededJournal extends JournalNotifier {
  _SeededJournal(this._log);
  final List<ConversationTurn> _log;
  @override
  List<ConversationTurn> get conversation => _log;
  @override
  JournalState build() => JournalState.empty();
}

class _LifecycleJournal extends JournalNotifier {
  final leaveCompleter = Completer<NotebookTransitionResult>();
  String? enteredNotebookId;
  bool? enteredWithAutoStart;
  int leaveCalls = 0;

  @override
  JournalState build() => JournalState.empty();

  @override
  Future<NotebookTransitionResult> enterNotebook(
    String notebookId, {
    bool autoStart = false,
  }) async {
    enteredNotebookId = notebookId;
    enteredWithAutoStart = autoStart;
    return const NotebookTransitionResult.success();
  }

  @override
  Future<NotebookTransitionResult> leaveNotebook() {
    leaveCalls += 1;
    return leaveCompleter.future;
  }
}

void main() {
  testWidgets('the transcript button turns the page to the conversation',
      (tester) async {
    // Phone-portrait surface so the page sizes from a real screen, not the
    // default 800x600 test window.
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const log = <ConversationTurn>[
      ConversationTurn(
        turnId: 'user-turn',
        role: Speaker.user,
        text: 'Had coffee with Maya about the Atlas launch.',
        createdAt: '2026-09-18T12:00:00Z',
      ),
      ConversationTurn(
        turnId: 'assistant-turn',
        role: Speaker.assistant,
        text: 'When did the Atlas launch slip?',
        createdAt: '2026-09-18T12:00:01Z',
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          journalProvider.overrideWith(() => _SeededJournal(log)),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: const JournalScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    // Graph view: the transcript page is not mounted.
    expect(find.byType(TranscriptPage), findsNothing);
    expect(
      find.text('Had coffee with Maya about the Atlas launch.'),
      findsNothing,
    );

    // Hand-drive the 580ms transition. pumpAndSettle would hang on
    // GraphCanvas's perpetual force-sim ticker, so step frames instead.
    await tester.tap(find.byIcon(Icons.article_outlined));
    for (var i = 0; i < 45; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(
      find.text('Had coffee with Maya about the Atlas launch.'),
      findsOneWidget,
    );
    expect(find.text('When did the Atlas launch slip?'), findsOneWidget);
    // The same button now offers the graph.
    expect(find.byIcon(Icons.article_outlined), findsNothing);
    expect(find.byIcon(Icons.hub_outlined), findsOneWidget);
    // The page covers the graph fully, so the graph stops painting.
    expect(
      find.ancestor(
        of: find.byType(GraphCanvas, skipOffstage: false),
        matching: find.byWidgetPredicate(
          (w) => w is Offstage && w.offstage,
          skipOffstage: false,
        ),
      ),
      findsOneWidget,
    );

    // And back: the page drops away and unmounts.
    await tester.tap(find.byIcon(Icons.hub_outlined));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(TranscriptPage), findsNothing);
    expect(find.byIcon(Icons.article_outlined), findsOneWidget);

    // Unmount so the GraphCanvas ticker disposes before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('home waits for notebook shutdown, then shows its card',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final journal = _LifecycleJournal();
    final router = GoRouter(
      initialLocation: '/notebook/notebook-a?start=true',
      routes: [
        GoRoute(
          path: '/notebook/:id',
          builder: (_, state) => JournalScreen(
            notebookId: state.pathParameters['id'],
            autoStart: state.uri.queryParameters['start'] == 'true',
          ),
          routes: [
            GoRoute(
              path: 'card',
              builder: (_, state) => Scaffold(
                body: Text('Card for ${state.pathParameters['id']}'),
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/dashboard',
          builder: (_, __) => const Scaffold(body: Text('Dashboard ready')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [journalProvider.overrideWith(() => journal)],
        child: MaterialApp.router(
          theme: LumenTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();

    expect(journal.enteredNotebookId, 'notebook-a');
    expect(journal.enteredWithAutoStart, isTrue);

    await tester.tap(find.bySemanticsLabel('Your notebooks'));
    await tester.pump();

    expect(journal.leaveCalls, 1);
    expect(find.text('Card for notebook-a'), findsNothing);

    journal.leaveCompleter.complete(
      const NotebookTransitionResult.success(),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Card for notebook-a'), findsOneWidget);
    expect(find.text('Dashboard ready'), findsNothing);
  });
}
