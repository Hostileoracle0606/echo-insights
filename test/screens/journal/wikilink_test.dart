import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/screens/journal/wikilink.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';

Widget _host(Widget child) {
  return MaterialApp(
    theme: LumenTheme.light(),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('tappable wikilink fires onTap with its id', (tester) async {
    String? tapped;

    await tester.pumpWidget(
      _host(
        WikiLink(
          entityId: 'atlas',
          label: 'Atlas',
          onTap: () => tapped = 'atlas',
        ),
      ),
    );

    await tester.tap(find.text('Atlas'));

    expect(tapped, 'atlas');
  });

  testWidgets('tappable wikilink uses ink text with amber underline',
      (tester) async {
    await tester.pumpWidget(
      _host(
        WikiLink(
          entityId: 'atlas',
          label: 'Atlas',
          onTap: () {},
        ),
      ),
    );

    final text = tester.widget<Text>(find.text('Atlas'));

    expect(text.style?.color, LumenColors.light.ink);
    expect(text.style?.decoration, TextDecoration.underline);
    expect(text.style?.decorationColor, LumenColors.light.amber);
  });

  testWidgets('null onTap renders plain, non-tappable, un-underlined text',
      (tester) async {
    await tester.pumpWidget(
      _host(
        const WikiLink(entityId: 'maya', label: 'Maya', onTap: null),
      ),
    );

    expect(find.text('Maya'), findsOneWidget);
    expect(find.byType(GestureDetector), findsNothing);

    final text = tester.widget<Text>(find.text('Maya'));

    expect(text.style?.color, LumenColors.light.ink);
    expect(text.style?.decoration, TextDecoration.none);
  });
}
