// Dashboard regression: notebooks bucket into Today / This week / Earlier by
// their start date, the hero totals sum correctly, and each card shows its
// title, summary, and meta (with a "live now" badge for an open session).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/notebook.dart';
import 'package:lumen/providers/notebooks_provider.dart';
import 'package:lumen/screens/dashboard/dashboard_screen.dart';
import 'package:lumen/theme/lumen_theme.dart';

Notebook _nb(
  String id,
  String title,
  Duration ago,
  int entities, {
  bool live = false,
}) {
  final started = DateTime.now().subtract(ago);
  return Notebook(
    id: id,
    userId: 'demo',
    title: title,
    titleSource: 'ai',
    startedAt: started,
    endedAt: live ? null : started.add(const Duration(minutes: 20)),
    entityCount: entities,
    summary: null,
    createdAt: started,
    updatedAt: started,
  );
}

void main() {
  testWidgets('groups notebooks by time and renders hero totals + cards',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final notebooks = [
      _nb('1', 'Atlas launch', const Duration(minutes: 5), 8, live: true),
      _nb('2', 'Lisbon trip', const Duration(days: 2), 11),
      _nb('3', 'Old brain-dump', const Duration(days: 40), 16),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notebooksProvider.overrideWith((ref) => notebooks),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: const DashboardScreen(),
        ),
      ),
    );
    // Drive the hero's one-shot intro (~1.3s); its amber pulse repeats forever,
    // so don't pumpAndSettle.
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Lumen. logotype (word + period are separate Texts) + the greeting stacked
    // one word per line (assert the first word) + summed totals + dock.
    expect(find.text('Lumen'), findsOneWidget);
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('3 sessions · 35 entities'), findsOneWidget);
    expect(find.text('New notebook'), findsOneWidget);

    // One bucket per spread.
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('EARLIER'), findsOneWidget);

    // Cards + the live badge on the open session.
    expect(find.text('Atlas launch'), findsOneWidget);
    expect(find.text('Lisbon trip'), findsOneWidget);
    expect(find.textContaining('live now'), findsOneWidget);

    // Unmount so the pulse ticker disposes before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows the empty state when there are no notebooks',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notebooksProvider.overrideWith((ref) => <Notebook>[]),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: const DashboardScreen(),
        ),
      ),
    );
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Greeting stacked one word per line → assert the first word.
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('New notebook'), findsOneWidget);
    expect(find.text('TODAY'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
