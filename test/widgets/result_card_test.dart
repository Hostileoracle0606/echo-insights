// ResultCard: the raised result card. Header, hero and rows render; the footer
// appears only when given; the corner button is a labelled 44pt target; both
// badge kinds render.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/result_card.dart';

Future<void> _pump(WidgetTester tester, Widget card) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: LumenTheme.light(),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: card,
        ),
      ),
    ),
  );
}

const _win =
    'Cut CI build time 41% (22 → 13 min) by fixing cache keys, with Priya.';

void main() {
  testWidgets('renders header, hero, rows and footer', (tester) async {
    await _pump(
      tester,
      ResultCard(
        eyebrow: 'This week · 3 wins',
        hero: const ResultRow(
          badge: ResultBadge.check(),
          label: 'Top win',
          text: _win,
          meta: 'Tuesday · with Priya',
        ),
        rows: const [
          ResultRow(
              badge: ResultBadge.check(), text: 'Shipped the onboarding fix'),
          ResultRow(
            badge: ResultBadge.check(),
            text: 'Paired with Sam on the flaky test',
            meta: 'Thursday',
          ),
        ],
        footerNote: '41 wins in your brief',
        footerActionLabel: 'Copy',
        onFooterAction: () {},
      ),
    );
    expect(find.text('THIS WEEK · 3 WINS'), findsOneWidget);
    expect(find.text('TOP WIN'), findsOneWidget);
    expect(find.text(_win), findsOneWidget);
    expect(find.text('Tuesday · with Priya'), findsOneWidget);
    expect(find.text('Shipped the onboarding fix'), findsOneWidget);
    expect(find.text('Thursday'), findsOneWidget);
    expect(find.text('41 wins in your brief'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('hero row sits on the highlight token', (tester) async {
    await _pump(
      tester,
      const ResultCard(
        eyebrow: 'Prep',
        hero: ResultRow(badge: ResultBadge.number(1), text: 'Start here'),
      ),
    );
    final hero = find.byKey(ResultCard.heroKey);
    expect(hero, findsOneWidget);
    final box = tester.widget<Container>(hero);
    expect((box.decoration as BoxDecoration?)?.color ?? box.color,
        LumenColors.light.highlight);
  });

  testWidgets('omits hero and footer when not given', (tester) async {
    await _pump(
      tester,
      const ResultCard(
        eyebrow: 'Bring these up',
        rows: [ResultRow(badge: ResultBadge.number(1), text: 'Priya')],
      ),
    );
    expect(find.byKey(ResultCard.heroKey), findsNothing);
    expect(find.byKey(ResultCard.footerKey), findsNothing);
    expect(find.byIcon(Icons.open_in_full), findsNothing);
  });

  testWidgets('footer note renders without an action', (tester) async {
    await _pump(
      tester,
      const ResultCard(
        eyebrow: 'This week',
        rows: [ResultRow(badge: ResultBadge.check(), text: 'One')],
        footerNote: '41 wins in your brief',
      ),
    );
    expect(find.byKey(ResultCard.footerKey), findsOneWidget);
    expect(find.text('41 wins in your brief'), findsOneWidget);
  });

  testWidgets('footer action is at least 44pt tall and fires', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      ResultCard(
        eyebrow: 'This week',
        footerNote: 'note',
        footerActionLabel: 'Copy',
        onFooterAction: () => taps++,
      ),
    );
    final action = find.bySemanticsLabel('Copy');
    expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
    await tester.tap(find.text('Copy'));
    expect(taps, 1);
  });

  testWidgets('corner button is 44x44, labelled, and fires onExpand',
      (tester) async {
    var expands = 0;
    await _pump(
      tester,
      ResultCard(
        eyebrow: 'This week',
        onExpand: () => expands++,
        expandLabel: 'Open your full review brief',
        rows: const [ResultRow(badge: ResultBadge.check(), text: 'One')],
      ),
    );
    final corner = find.bySemanticsLabel('Open your full review brief');
    expect(corner, findsOneWidget);
    final size = tester.getSize(corner);
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
    final icon = tester.widget<Icon>(find.byIcon(Icons.open_in_full));
    expect(icon.size, 16);
    expect(icon.color, LumenColors.light.mutedForeground);
    await tester.tap(corner);
    expect(expands, 1);
  });

  test('corner button requires a label', () {
    expect(
      () => ResultCard(eyebrow: 'x', onExpand: () {}),
      throwsAssertionError,
    );
  });

  testWidgets('number and check badges both render', (tester) async {
    await _pump(
      tester,
      const ResultCard(
        eyebrow: 'Start here',
        hero: ResultRow(badge: ResultBadge.number(1), text: 'First'),
        rows: [
          ResultRow(badge: ResultBadge.number(2), text: 'Second'),
          ResultRow(badge: ResultBadge.check(), text: 'Done'),
        ],
      ),
    );
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
    // Hero badge is ink with paper text; the plain row's check is lumenLabel.
    expect(tester.widget<Text>(find.text('1')).style!.color,
        LumenColors.light.paper);
    expect(tester.widget<Icon>(find.byIcon(Icons.check)).color,
        LumenColors.light.lumenLabel);
  });

  testWidgets('a row with onTap fires it', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      ResultCard(
        eyebrow: 'Quotes',
        rows: [
          ResultRow(
            badge: const ResultBadge.number(1),
            text: 'Open this conversation',
            onTap: () => taps++,
          ),
        ],
      ),
    );
    await tester.tap(find.text('Open this conversation'));
    expect(taps, 1);
  });
}
