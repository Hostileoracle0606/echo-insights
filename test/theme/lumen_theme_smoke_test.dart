import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';

void main() {
  testWidgets('a screen under LumenTheme resolves tokens and renders',
      (tester) async {
    late LumenColors readColors;
    await tester.pumpWidget(
      MaterialApp(
        theme: LumenTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              readColors = context.lumenColors;
              return Text(
                'Lumen',
                style: Theme.of(context).textTheme.displayLarge,
              );
            },
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(readColors, LumenColors.light);
    expect(find.text('Lumen'), findsOneWidget);
  });
}
