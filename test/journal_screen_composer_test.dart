// LM-12: the composer wired into the real JournalScreen — Type opens it and
// pauses the mic, its mic closes it and resumes, Send goes to
// sendTypedTurn, and typed rows are marked in the transcript.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/composer.dart';
import 'package:lumen/screens/journal/graph_canvas.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _ComposerJournal extends JournalNotifier {
  _ComposerJournal({this.current = SessionStatus.live, this.log = const []});

  SessionStatus current;
  final List<ConversationTurn> log;
  int pauses = 0;
  int resumes = 0;
  final typed = <String>[];

  @override
  JournalState build() => JournalState.empty();

  @override
  SessionStatus get status => current;

  @override
  List<ConversationTurn> get conversation => log;

  @override
  Future<void> pauseMic() async {
    pauses += 1;
    if (current == SessionStatus.live) current = SessionStatus.paused;
    state = state.copyWith();
  }

  @override
  Future<NotebookTransitionResult> resumeMic() async {
    resumes += 1;
    current = SessionStatus.live;
    state = state.copyWith();
    return const NotebookTransitionResult.success();
  }

  @override
  bool sendTypedTurn(String text) {
    typed.add(text);
    return true;
  }
}

Future<_ComposerJournal> _pump(
  WidgetTester tester, {
  SessionStatus status = SessionStatus.live,
  List<ConversationTurn> log = const [],
  double width = 402,
}) async {
  final journal = _ComposerJournal(current: status, log: log);
  tester.view
    ..physicalSize = Size(width, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [journalProvider.overrideWith(() => journal)],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: LumenTheme.light(),
        home: const JournalScreen(),
      ),
    ),
  );
  await _frames(tester);
  return journal;
}

// The graph's force simulation ticks forever, so step frames rather than
// pumpAndSettle.
Future<void> _frames(WidgetTester tester, {int count = 45}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _openComposer(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Type instead'));
  await _frames(tester);
}

void main() {
  testWidgets('Type opens the composer, pauses the mic and focuses the field',
      (tester) async {
    final journal = await _pump(tester);

    await _openComposer(tester);

    expect(journal.pauses, 1);
    expect(find.byType(Composer), findsOneWidget);
    expect(find.bySemanticsLabel('Microphone'), findsNothing,
        reason: 'the composer replaces the button row');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    expect(find.text('Paused'), findsNothing,
        reason: 'typing is not a paused session');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the composer mic closes it and resumes voice', (tester) async {
    final journal = await _pump(tester);
    await _openComposer(tester);

    await tester.tap(find.bySemanticsLabel('Switch to voice'));
    await _frames(tester);

    expect(journal.resumes, 1);
    expect(find.byType(Composer), findsNothing);
    expect(find.bySemanticsLabel('Microphone'), findsOneWidget);
    expect(journal.status, SessionStatus.live);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sending calls sendTypedTurn, clears the field and stays open',
      (tester) async {
    final journal = await _pump(tester);
    await _openComposer(tester);

    await tester.enterText(find.byType(TextField), 'Maya signed off.');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    await _frames(tester, count: 5);

    expect(journal.typed, ['Maya signed off.']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.byType(Composer), findsOneWidget);
    expect(journal.resumes, 0, reason: 'the mic stays paused');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with the composer open the pill stays centred, and the mic '
      'sits on its row\'s centre line', (tester) async {
    for (final width in [375.0, 402.0, 820.0]) {
      await _pump(tester, width: width);
      await _openComposer(tester);

      final pill = tester.getCenter(find.byKey(VoiceDock.pillKey));
      expect(pill.dx, moreOrLessEquals(width / 2, epsilon: 0.5),
          reason: 'pill at ${width}pt');
      final mic = tester.getCenter(find.bySemanticsLabel('Switch to voice'));
      final field = tester.getCenter(find.byType(TextField));
      final send = tester.getCenter(find.bySemanticsLabel('Send'));
      expect(mic.dy, moreOrLessEquals(field.dy, epsilon: 0.5),
          reason: 'mic and field at ${width}pt');
      expect(mic.dy, moreOrLessEquals(send.dy, epsilon: 0.5),
          reason: 'mic and Send at ${width}pt');
      expect(mic.dx, lessThan(field.dx), reason: 'the mic slides left');

      // Closing the composer puts the pill's mic back on the screen centre.
      await tester.tap(find.bySemanticsLabel('Switch to voice'));
      await _frames(tester);
      expect(
        tester.getCenter(find.bySemanticsLabel('Microphone')).dx,
        moreOrLessEquals(width / 2, epsilon: 0.5),
        reason: 'mic back on the centre line at ${width}pt',
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the keyboard lifts the pill, not the graph', (tester) async {
    await _pump(tester);
    await _openComposer(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    await _frames(tester, count: 5);

    expect(tester.getRect(find.byKey(VoiceDock.pillKey)).bottom,
        moreOrLessEquals(874 - 336 - 8, epsilon: 0.5));
    expect(tester.getSize(find.byType(GraphCanvas)), const Size(402, 874));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a multi-line message keeps the buttons on its last line',
      (tester) async {
    await _pump(tester);
    await _openComposer(tester);
    await tester.enterText(find.byType(TextField),
        'One line\nTwo lines\nThree lines, and a fourth to be sure');
    await _frames(tester, count: 40);

    final field = tester.getRect(find.byType(TextField));
    expect(field.height, greaterThan(60));
    for (final label in ['Switch to voice', 'Send']) {
      expect(tester.getRect(find.bySemanticsLabel(label)).bottom,
          moreOrLessEquals(field.bottom, epsilon: 0.5),
          reason: label);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without a session there is nothing to type to', (tester) async {
    await _pump(tester, status: SessionStatus.idle);
    expect(find.bySemanticsLabel('Type instead'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the composer closes when the session ends', (tester) async {
    final journal = await _pump(tester);
    await _openComposer(tester);

    journal
      ..current = SessionStatus.idle
      ..state = journal.state.copyWith();
    await _frames(tester);

    expect(find.byType(Composer), findsNothing);
    journal
      ..current = SessionStatus.live
      ..state = journal.state.copyWith();
    await _frames(tester);
    expect(find.byType(Composer), findsNothing,
        reason: 'a new session starts on voice');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('typed rows say so beside their time in the transcript',
      (tester) async {
    await _pump(tester, log: const [
      ConversationTurn(
        turnId: 'spoken',
        role: Speaker.user,
        text: 'I finished the Atlas draft.',
        createdAt: '2026-10-23T17:03:00Z',
      ),
      ConversationTurn(
        turnId: 'typed',
        role: Speaker.user,
        text: 'Maya signed off.',
        createdAt: '2026-10-23T17:04:00Z',
        input: TurnInput.typed,
      ),
      ConversationTurn(
        turnId: 'reply',
        role: Speaker.assistant,
        text: 'Congratulations.',
        createdAt: '2026-10-23T17:04:05Z',
      ),
    ]);

    await tester.tap(find.bySemanticsLabel('Show transcript'));
    await _frames(tester);

    expect(find.textContaining('typed · '), findsOneWidget);
    final label = tester.widget<Text>(find.textContaining('typed · '));
    final local = DateTime.parse('2026-10-23T17:04:00Z').toLocal();
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    expect(label.data,
        'typed · $h:${local.minute.toString().padLeft(2, '0')}');
    await tester.pumpWidget(const SizedBox());
  });
}
