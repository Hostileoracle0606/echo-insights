// LM-103: while catch-up is making a notebook's card, its dashboard row says
// so in one calm line; otherwise the row is as it was.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/notebook.dart';
import 'package:lumen/providers/catch_up_provider.dart';
import 'package:lumen/providers/notebooks_provider.dart';
import 'package:lumen/screens/dashboard/dashboard_screen.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/finishing_up.dart';

class _FixedCatchUp extends CatchUpNotifier {
  _FixedCatchUp(this.initial);
  final CatchUpState initial;

  @override
  CatchUpState build() => initial;
}

Notebook _nb(String id, String title) {
  final started = DateTime.now().subtract(const Duration(hours: 1));
  return Notebook(
    id: id,
    userId: 'demo',
    title: title,
    titleSource: 'ai',
    startedAt: started,
    endedAt: started.add(const Duration(minutes: 20)),
    entityCount: 2,
    summary: null,
    createdAt: started,
    updatedAt: started,
  );
}

Future<void> _pumpDashboard(WidgetTester tester, CatchUpState state) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        notebooksProvider
            .overrideWith((ref) => [_nb('nb1', 'Atlas'), _nb('nb2', 'Lisbon')]),
        catchUpProvider.overrideWith(() => _FixedCatchUp(state)),
      ],
      child: MaterialApp(
        theme: LumenTheme.light(),
        home: const DashboardScreen(),
      ),
    ),
  );
  for (var i = 0; i < 90; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  test('the copy is calm and claims nothing', () {
    expect(finishingUpCopy, 'Finishing up…');
  });

  testWidgets('a notebook whose card is pending shows "Finishing up…"',
      (tester) async {
    await _pumpDashboard(
      tester,
      const CatchUpState(running: true, pendingCardNotebookIds: {'nb2'}),
    );

    expect(find.text(finishingUpCopy), findsOneWidget);
    final row = find.ancestor(
      of: find.text(finishingUpCopy),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(of: row, matching: find.text('Lisbon')),
      findsOneWidget,
    );
    // Muted like the row's meta line: no alarm colour, no icon.
    final text = tester.widget<Text>(find.text(finishingUpCopy));
    final colors = tester.element(find.text(finishingUpCopy)).lumenColors;
    expect(text.style?.color, colors.mutedForeground);
    expect(
      find.descendant(
        of: find.byType(FinishingUpNote),
        matching: find.byType(Icon),
      ),
      findsNothing,
    );
  });

  testWidgets('nothing shows when catch-up is idle', (tester) async {
    await _pumpDashboard(tester, CatchUpState.idle);
    expect(find.text(finishingUpCopy), findsNothing);
  });

  testWidgets('nothing shows once the run has ended, even with stale ids',
      (tester) async {
    await _pumpDashboard(
      tester,
      const CatchUpState(running: false, pendingCardNotebookIds: {'nb1'}),
    );
    expect(find.text(finishingUpCopy), findsNothing);
  });
}
