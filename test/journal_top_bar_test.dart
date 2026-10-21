// JournalTopBar session controls: mute and End moved here from the dock.
// Mute reflects its state and fires onMuteTap; End fires onEndTap and is
// dimmed and inert without a session; both keep a 44pt hit box.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/screens/journal/journal_top_bar.dart';
import 'package:lumen/theme/lumen_theme.dart';

Future<void> _pump(WidgetTester tester, JournalTopBar bar) async {
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: bar,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('volume reflects mute state and fires onMuteTap', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      JournalTopBar(
        entityCount: 3,
        relationCount: 2,
        onMuteTap: () => taps++,
      ),
    );
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byIcon(Icons.volume_off), findsNothing);
    expect(find.bySemanticsLabel('Mute Lumen'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.volume_up));
    expect(taps, 1);
  });

  testWidgets('a muted bar shows the muted icon', (tester) async {
    await _pump(
      tester,
      JournalTopBar(
        entityCount: 3,
        relationCount: 2,
        muted: true,
        onMuteTap: () {},
      ),
    );
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNothing);
    expect(find.bySemanticsLabel('Unmute Lumen'), findsOneWidget);
  });

  testWidgets('End fires onEndTap, and is inert without a session',
      (tester) async {
    var ends = 0;
    await _pump(
      tester,
      const JournalTopBar(entityCount: 3, relationCount: 2),
    );
    await tester.tap(find.text('End'));
    expect(
      tester.getSemantics(find.bySemanticsLabel('End session')),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
    );

    await _pump(
      tester,
      JournalTopBar(
        entityCount: 3,
        relationCount: 2,
        onEndTap: () => ends++,
      ),
    );
    await tester.tap(find.text('End'));
    expect(ends, 1);
    expect(
      tester.getSemantics(find.bySemanticsLabel('End session')),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: true),
    );
  });

  testWidgets('mute and End keep a 44pt hit box', (tester) async {
    await _pump(
      tester,
      JournalTopBar(
        entityCount: 3,
        relationCount: 2,
        onMuteTap: () {},
        onEndTap: () {},
      ),
    );
    for (final label in ['Mute Lumen', 'End session']) {
      final size = tester.getSize(find.bySemanticsLabel(label));
      expect(size.width, greaterThanOrEqualTo(44), reason: label);
      expect(size.height, greaterThanOrEqualTo(44), reason: label);
    }
  });
}
