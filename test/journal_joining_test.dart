// Phase 3: a new notebook opens at once while Lumen joins; if Lumen can't
// join, a banner offers Retry and opening without voice.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _JoiningJournal extends JournalNotifier {
  _JoiningJournal(this.phase);
  JoiningPhase phase;
  int retries = 0;
  int withoutVoice = 0;

  @override
  JournalState build() => JournalState.empty();

  @override
  JoiningPhase get joining => phase;

  @override
  Future<NotebookTransitionResult> retryJoining() async {
    retries += 1;
    return const NotebookTransitionResult.success();
  }

  @override
  Future<void> openWithoutVoice() async => withoutVoice += 1;
}

Future<_JoiningJournal> _pump(WidgetTester tester, JoiningPhase phase) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final journal = _JoiningJournal(phase);
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
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return journal;
}

void main() {
  testWidgets('while Lumen joins, the page shows at once, with no loader',
      (tester) async {
    await _pump(tester, JoiningPhase.joining);

    // The greeting plays while the socket connects; the dock says who has
    // the floor, so nothing covers the page.
    expect(find.text('Lumen is joining…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text("Lumen couldn't join"), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed join offers Retry and opening without voice',
      (tester) async {
    final journal = await _pump(tester, JoiningPhase.failed);

    expect(find.text("Lumen couldn't join"), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('Open without voice'));
    expect(journal.retries, 1);
    expect(journal.withoutVoice, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an opened notebook shows neither', (tester) async {
    await _pump(tester, JoiningPhase.none);

    expect(find.text('Lumen is joining…'), findsNothing);
    expect(find.text("Lumen couldn't join"), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
