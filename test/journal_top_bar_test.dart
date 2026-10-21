// JournalTopBar session controls: mute and End moved here from the dock.
// Mute reflects its state and fires onMuteTap; End fires onEndTap and is
// dimmed and inert without a session; both keep a 44pt hit box. And the bar
// fits a 375pt screen with the real fonts.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/screens/journal/journal_top_bar.dart';
import 'package:lumen/theme/lumen_theme.dart';

Future<void> _loadFont(String family, String path) async {
  final bytes = await File(path).readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

Future<void> _pump(
  WidgetTester tester,
  JournalTopBar bar, {
  double width = 402,
}) async {
  tester.view
    ..physicalSize = Size(width, 874)
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

  group('at 375pt with the real fonts', () {
    setUpAll(() async {
      await _loadFont('Inter', 'assets/fonts/Inter.ttf');
      await _loadFont('Fraunces', 'assets/fonts/Fraunces.ttf');
      // Material glyphs: the local SDK cache; skip gracefully if it moves.
      const icons = '/opt/homebrew/share/flutter/bin/cache/artifacts/'
          'material_fonts/MaterialIcons-Regular.otf';
      if (File(icons).existsSync()) await _loadFont('MaterialIcons', icons);
    });

    testWidgets('back, mute, End and stats fit with no overflow',
        (tester) async {
      var homes = 0;
      await _pump(
        tester,
        JournalTopBar(
          entityCount: 128,
          relationCount: 342,
          onHomeTap: () => homes++,
          onMenuTap: () {},
          onMuteTap: () {},
          onEndTap: () {},
        ),
        width: 375,
      );
      // A RenderFlex overflow would surface here.
      expect(tester.takeException(), isNull);

      final back = find.bySemanticsLabel('Your notebooks');
      expect(tester.getSize(back), const Size(44, 44));
      await tester.tap(back);
      expect(homes, 1);

      // Left to right: back · mute · End · stats, all on screen.
      final xs = [
        tester.getRect(back).right,
        tester.getCenter(find.bySemanticsLabel('Mute Lumen')).dx,
        tester.getCenter(find.text('End')).dx,
        tester.getCenter(find.text('128')).dx,
      ];
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]));
      }
      expect(tester.getRect(find.text(' · 342')).right, lessThan(375 - 16));
    });
  });
}
