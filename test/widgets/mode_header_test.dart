// ModeHeader: back fires, carries "Back, <title>", and at 375pt with a 150pt
// trailing widget a long title ellipsizes instead of overflowing.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/mode_header.dart';

Future<void> _loadFont(String family, String path) async {
  final bytes = await File(path).readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

Future<void> _pump(WidgetTester tester, ModeHeader header,
    {double width = 402}) async {
  tester.view
    ..physicalSize = Size(width, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      home: Scaffold(body: SafeArea(child: Column(children: [header]))),
    ),
  );
}

void main() {
  setUpAll(() async {
    await _loadFont('Inter', 'assets/fonts/Inter.ttf');
    await _loadFont('Fraunces', 'assets/fonts/Fraunces.ttf');
  });

  testWidgets('back fires and is a labelled 44pt target', (tester) async {
    var backs = 0;
    await _pump(
      tester,
      ModeHeader(title: 'Weekly debrief', onBack: () => backs++),
    );
    final back = find.bySemanticsLabel('Back, Weekly debrief');
    expect(back, findsOneWidget);
    expect(tester.getSize(back).height, greaterThanOrEqualTo(44));
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    await tester.tap(back);
    expect(backs, 1);
  });

  testWidgets('long title ellipsizes before a 150pt trailing at 375pt',
      (tester) async {
    await _pump(
      tester,
      ModeHeader(
        title: 'Prepare for your one-on-one with Priya about the CI rollout',
        onBack: () {},
        trailing: const SizedBox(
          key: ValueKey('trailing'),
          width: 150,
          height: 36,
        ),
      ),
      width: 375,
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const ValueKey('trailing'))).width, 150);
    final title = tester.widget<Text>(
      find.text('Prepare for your one-on-one with Priya about the CI rollout'),
    );
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    final para = tester.renderObject<RenderParagraph>(
      find.text('Prepare for your one-on-one with Priya about the CI rollout'),
    );
    expect(para.didExceedMaxLines, isTrue);
    // Trailing hugs the right padding (16pt).
    expect(tester.getTopRight(find.byKey(const ValueKey('trailing'))).dx,
        375 - 16);
  });

  testWidgets('default padding is 18 top, 16 right, 10 left', (tester) async {
    await _pump(
      tester,
      ModeHeader(
        title: 'Ask',
        onBack: () {},
        trailing: const SizedBox(key: ValueKey('t'), width: 40, height: 44),
      ),
    );
    final back = find.bySemanticsLabel('Back, Ask');
    expect(tester.getTopLeft(back), const Offset(10, 18));
    expect(tester.getTopRight(find.byKey(const ValueKey('t'))).dx, 402 - 16);
  });
}
