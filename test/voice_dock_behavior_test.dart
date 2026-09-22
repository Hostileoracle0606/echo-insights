// Dynamic-island (VoiceDock) behavior: verifies the dock reacts to its props —
// mic/split/mute taps fire their callbacks, the mute icon reflects state, and
// the split-screen morph surfaces the conversation as bubbles.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/theme/lumen_theme.dart';

Future<void> _pump(WidgetTester tester, VoiceDock dock) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: dock),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  testWidgets('tapping the mic fires onMicTap', (tester) async {
    var taps = 0;
    await _pump(tester, VoiceDock(mode: DockMode.idle, onMicTap: () => taps++));
    await tester.tap(find.byIcon(Icons.mic));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the split toggle fires onToggleSplit', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.idle,
        onMicTap: () {},
        onToggleSplit: () => taps++,
      ),
    );
    await tester.tap(find.byIcon(Icons.splitscreen));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('volume reflects mute state and fires onMuteTap', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.idle,
        muted: false,
        onMicTap: () {},
        onMuteTap: () => taps++,
      ),
    );
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byIcon(Icons.volume_off), findsNothing);
    await tester.tap(find.byIcon(Icons.volume_up));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a muted dock shows the muted icon', (tester) async {
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.listening,
        muted: true,
        onMicTap: () {},
        onMuteTap: () {},
      ),
    );
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('expanded dock surfaces the conversation as bubbles',
      (tester) async {
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.listening,
        expanded: true,
        turns: const [
          DockTurn(DockSpeaker.you, 'Had coffee with Maya.'),
          DockTurn(DockSpeaker.lumen, 'When was the Atlas launch?'),
        ],
        onMicTap: () {},
      ),
    );
    // Let the (repeating-pulse) dock lay out; don't pumpAndSettle.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Had coffee with Maya.'), findsOneWidget);
    expect(find.text('When was the Atlas launch?'), findsOneWidget);
    // The pinned controls remain reachable while expanded.
    expect(find.byIcon(Icons.mic), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('collapsed dock hides transcript turns', (tester) async {
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.idle,
        turns: const [DockTurn(DockSpeaker.you, 'Hidden while collapsed')],
        onMicTap: () {},
      ),
    );
    expect(find.text('Hidden while collapsed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
