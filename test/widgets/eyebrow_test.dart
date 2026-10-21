// Eyebrow shows its text uppercase but gives screen readers the normal-case
// text, so VoiceOver reads words instead of spelling out capitals.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/eyebrow.dart';

void main() {
  testWidgets('displays uppercase, announces the original text',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumenTheme.light(),
        home: const Scaffold(body: Eyebrow('This week · 3 wins')),
      ),
    );
    expect(find.text('THIS WEEK · 3 WINS'), findsOneWidget);
    expect(find.bySemanticsLabel('This week · 3 wins'), findsOneWidget);
    expect(find.bySemanticsLabel('THIS WEEK · 3 WINS'), findsNothing);
  });

  testWidgets('defaults to mutedForeground and takes a colour', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LumenTheme.light(),
        home: Scaffold(
          body: Column(
            children: [
              const Eyebrow('Ask'),
              Eyebrow('Top win', color: LumenColors.light.youLabel),
            ],
          ),
        ),
      ),
    );
    final ask = tester.widget<Text>(find.text('ASK'));
    final top = tester.widget<Text>(find.text('TOP WIN'));
    expect(ask.style!.color, LumenColors.light.mutedForeground);
    expect(top.style!.color, LumenColors.light.youLabel);
    expect(ask.style!.fontSize, 10);
  });
}
