// The transcript page holds Lumen's place while it mulls over a reply.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/screens/journal/transcript_page.dart';
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/breathing_dots.dart';

Future<void> _pump(WidgetTester tester, {required bool mulling}) async {
  await tester.pumpWidget(MaterialApp(
    theme: LumenTheme.light(),
    home: Scaffold(
      body: TranscriptPage(
        turns: [
          TranscriptTurn(DockSpeaker.you, 'What should I build next?',
              id: 'u1', typed: true, at: DateTime(2026, 10, 27, 12, 33)),
        ],
        lumenMulling: mulling,
      ),
    ),
  ));
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('a Lumen row with breathing dots sits under the last turn',
      (tester) async {
    await _pump(tester, mulling: true);

    expect(find.text('LUMEN'), findsOneWidget);
    expect(find.byType(BreathingDots), findsOneWidget);
    final you = tester.getTopLeft(find.text('YOU')).dy;
    final lumen = tester.getTopLeft(find.text('LUMEN')).dy;
    expect(lumen, greaterThan(you), reason: 'where the reply will appear');
  });

  testWidgets('and goes when Lumen is not mulling', (tester) async {
    await _pump(tester, mulling: false);

    expect(find.text('LUMEN'), findsNothing);
    expect(find.byType(BreathingDots), findsNothing);
  });
}
