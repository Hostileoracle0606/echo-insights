// Stitch regression: the pill's split toggle should morph the dock open and
// surface the provider's conversation log as ChatGPT-style turns in the panel.
// Exercises the real JournalScreen (not a composed stand-in) so the wiring —
// toggle -> setState -> expanded -> conversationProvider -> turns — is covered.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _SeededJournal extends JournalNotifier {
  _SeededJournal(this._log);
  final List<({String role, String text})> _log;
  @override
  List<({String role, String text})> get conversation => _log;
  @override
  JournalState build() => JournalState.empty();
}

void main() {
  testWidgets('split toggle morphs the dock open and shows the conversation',
      (tester) async {
    // Phone-portrait surface so the dock sizes from a real screen, not the
    // default 800x600 test window.
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const log = <({String role, String text})>[
      (role: 'user', text: 'Had coffee with Maya about the Atlas launch.'),
      (role: 'agent', text: 'When did the Atlas launch slip?'),
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

    // Collapsed: the dock is a rest pill, the transcript isn't mounted, but the
    // pill's split toggle is present and ready.
    expect(find.byIcon(Icons.splitscreen), findsOneWidget);
    expect(
      find.text('Had coffee with Maya about the Atlas launch.'),
      findsNothing,
    );

    // Tap the toggle, then hand-drive the 520ms morph. pumpAndSettle would hang
    // on GraphCanvas's perpetual force-sim ticker, so step frames instead.
    await tester.tap(find.byIcon(Icons.splitscreen));
    for (var i = 0; i < 45; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Expanded: the seeded log now renders as bubbles in the panel.
    expect(
      find.text('Had coffee with Maya about the Atlas launch.'),
      findsOneWidget,
    );
    expect(find.text('When did the Atlas launch slip?'), findsOneWidget);

    // Unmount so the GraphCanvas ticker disposes before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}
