// ContextTile and ContextList: the flat muted context tiles. Remove fires with
// the right item, and every remove button carries its own label.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/context_tile.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: LumenTheme.light(),
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
}

const _items = [
  ContextItem(title: 'Priya', note: 'paired on CI'),
  ContextItem(title: 'CI cache keys'),
  ContextItem(title: 'Ask about the Q4 plan', open: true),
];

void main() {
  testWidgets('ContextTile renders eyebrow, body and icon on muted',
      (tester) async {
    await _pump(
      tester,
      const ContextTile(
        icon: Icons.chat_bubble_outline,
        eyebrow: 'Since last time',
        body: 'You said the CI fix would free up Fridays.',
      ),
    );
    expect(find.text('SINCE LAST TIME'), findsOneWidget);
    expect(find.text('You said the CI fix would free up Fridays.'),
        findsOneWidget);
    final icon = tester.widget<Icon>(find.byIcon(Icons.chat_bubble_outline));
    expect(icon.size, 18);
    expect(icon.color, LumenColors.light.ink);
    final box = tester.widget<Container>(
      find
          .descendant(
            of: find.byKey(ContextTile.surfaceKey),
            matching: find.byType(Container),
          )
          .first,
    );
    final deco = box.decoration! as BoxDecoration;
    expect(deco.color, LumenColors.light.muted);
    expect(deco.boxShadow, isNull);
    expect(deco.borderRadius, BorderRadius.circular(14));
  });

  testWidgets('ContextList renders items, notes and dots', (tester) async {
    await _pump(
      tester,
      const ContextList(eyebrow: 'Lumen will remember', items: _items),
    );
    expect(find.text('LUMEN WILL REMEMBER'), findsOneWidget);
    expect(find.textContaining('Priya'), findsOneWidget);
    expect(find.textContaining('paired on CI'), findsOneWidget);
    expect(find.byKey(const ValueKey('context-dot-filled')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('context-dot-open')), findsOneWidget);
    // No onRemove, no remove buttons.
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('remove fires with the right item; each has its own label',
      (tester) async {
    final removed = <ContextItem>[];
    await _pump(
      tester,
      ContextList(
        eyebrow: 'Lumen will remember',
        items: _items,
        onRemove: removed.add,
      ),
    );
    expect(find.bySemanticsLabel('Remove Priya'), findsOneWidget);
    expect(find.bySemanticsLabel('Remove CI cache keys'), findsOneWidget);
    expect(
        find.bySemanticsLabel('Remove Ask about the Q4 plan'), findsOneWidget);

    final button = find.bySemanticsLabel('Remove CI cache keys');
    final size = tester.getSize(button);
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));

    await tester.tap(button);
    expect(removed, [_items[1]]);
    await tester.tap(find.bySemanticsLabel('Remove Priya'));
    expect(removed, [_items[1], _items[0]]);
  });

  testWidgets('an item can override its remove label', (tester) async {
    await _pump(
      tester,
      ContextList(
        eyebrow: 'Ask',
        items: const [
          ContextItem(title: 'Q4', removeLabel: 'Forget the Q4 plan'),
        ],
        onRemove: (_) {},
      ),
    );
    expect(find.bySemanticsLabel('Forget the Q4 plan'), findsOneWidget);
  });
}
