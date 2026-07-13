// Phase 2 regression: the dock's volume control is wired to a real mute flag
// (not a no-op), and the notifier's derived providers reflect it.
//
// Two layers:
//  * A pure-provider test drives JournalNotifier.toggleMute() directly through
//    a bare ProviderContainer (no widget tree) and checks mutedProvider.
//  * A widget test drives the real JournalScreen and taps the actual volume
//    icon, proving the onMuteTap wiring end to end.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/session_provider.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _SeededJournal extends JournalNotifier {
  @override
  JournalState build() => JournalState.empty();
}

void main() {
  test('toggleMute flips muted and mutedProvider reflects it', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(mutedProvider), isFalse);
    expect(container.read(agentSpeakingProvider), isFalse);

    container.read(journalProvider.notifier).toggleMute();
    expect(container.read(mutedProvider), isTrue);
    expect(container.read(journalProvider.notifier).muted, isTrue);

    container.read(journalProvider.notifier).toggleMute();
    expect(container.read(mutedProvider), isFalse);
  });

  testWidgets('volume icon toggles when the dock control is tapped',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          journalProvider.overrideWith(_SeededJournal.new),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: const JournalScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));

    // Idle dock: unmuted by default.
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byIcon(Icons.volume_off), findsNothing);

    await tester.tap(find.byIcon(Icons.volume_up));
    await tester.pump();

    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNothing);

    await tester.tap(find.byIcon(Icons.volume_off));
    await tester.pump();

    expect(find.byIcon(Icons.volume_up), findsOneWidget);

    // Unmount so the GraphCanvas ticker disposes before the test ends.
    await tester.pumpWidget(const SizedBox());
  });
}
