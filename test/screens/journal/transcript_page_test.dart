// TranscriptPage: the rolling conversation — spoken order with the newest at
// the bottom, pending turns faded, entities marked, a day header above it all,
// and a jump-to-latest chip once the reader scrolls back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/entity_highlighter.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/screens/journal/transcript_page.dart';
import 'package:lumen/screens/journal/voice_dock.dart' show DockSpeaker;
import 'package:lumen/theme/lumen_theme.dart';

Future<void> _pump(WidgetTester tester, List<TranscriptTurn> turns,
    {List<HighlightTerm> terms = const []}) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      home: Scaffold(body: TranscriptPage(turns: turns, terms: terms)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
}

TranscriptTurn _t(int i, DockSpeaker who, String text,
        {bool pending = false}) =>
    TranscriptTurn(who, text,
        id: 't$i', pending: pending, at: DateTime(2026, 9, 25, 9, 41 + i));

void main() {
  testWidgets('turns read top to bottom in spoken order', (tester) async {
    await _pump(tester, [
      _t(0, DockSpeaker.lumen, 'How is it sitting today?'),
      _t(1, DockSpeaker.you, 'Honestly, lighter.'),
    ]);
    final lumen = tester.getTopLeft(find.text('How is it sitting today?'));
    final you = tester.getTopLeft(find.text('Honestly, lighter.'));
    expect(lumen.dy, lessThan(you.dy));
    expect(find.text('LUMEN'), findsOneWidget);
    expect(find.text('YOU'), findsOneWidget);
    expect(find.text('9:41'), findsOneWidget);
    expect(find.text('Friday, 25 September'), findsOneWidget);
  });

  testWidgets('a pending turn is faded in its slot', (tester) async {
    await _pump(tester, [
      _t(0, DockSpeaker.you, 'Still talking', pending: true),
    ]);
    final opacity = tester.widget<Opacity>(find
        .ancestor(
            of: find.text('Still talking'), matching: find.byType(Opacity))
        .first);
    expect(opacity.opacity, 0.6);
  });

  testWidgets('entities are marked in their graph colour', (tester) async {
    await _pump(
      tester,
      [_t(0, DockSpeaker.you, 'Coffee with Maya in Lisbon.')],
      terms: const [
        HighlightTerm('Maya', EntityType.person),
        HighlightTerm('Lisbon', EntityType.place),
      ],
    );
    final text = tester.widget<Text>(find.text('Coffee with Maya in Lisbon.'));
    final marked = (text.textSpan! as TextSpan)
        .children!
        .cast<TextSpan>()
        .where((s) => s.style?.backgroundColor != null)
        .map((s) => s.text);
    expect(marked, ['Maya', 'Lisbon']);
  });

  testWidgets('an empty conversation invites speech', (tester) async {
    await _pump(tester, const []);
    expect(find.text('Your conversation will appear here as you speak.'),
        findsOneWidget);
  });

  testWidgets('scrolling back offers a jump to the latest', (tester) async {
    await _pump(tester, [
      for (var i = 0; i < 30; i++)
        _t(i, i.isEven ? DockSpeaker.you : DockSpeaker.lumen,
            'Line $i of a long conversation that wraps across the page.'),
    ]);
    double chip() => tester
        .widget<FadeTransition>(find
            .ancestor(
                of: find.text('Jump to latest'),
                matching: find.byType(FadeTransition))
            .first)
        .opacity
        .value;
    expect(chip(), 0);

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(chip(), 1);

    await tester.tap(find.text('Jump to latest'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
        find.text('Line 29 of a long conversation that wraps across the page.'),
        findsOneWidget);
    expect(chip(), 0);
  });
}
