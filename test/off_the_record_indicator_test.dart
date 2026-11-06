// LM-50: the always-visible off-the-record state, in both views, and the
// words it uses when the switch goes on after turns were saved.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/quiet_mode_provider.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/screens/journal/journal_top_bar.dart';
import 'package:lumen/screens/journal/off_the_record_indicator.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _Journal extends JournalNotifier {
  _Journal({required this.saved});
  final bool saved;

  @override
  JournalState build() => JournalState.empty();

  @override
  bool get hasSavedTurns => saved;
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  required bool saved,
  bool quietSilenced = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        journalProvider.overrideWith(() => _Journal(saved: saved)),
        quietPlaybackAllowedProvider.overrideWithValue(!quietSilenced),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: LumenTheme.light(),
        home: const JournalScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  const midSession =
      'Nothing from here on is saved. What you said earlier stays.';

  testWidgets('the indicator is absent on the record', (tester) async {
    await _pumpScreen(tester, saved: true);
    expect(find.byKey(const Key('offTheRecordIndicator')), findsNothing);
    expect(find.bySemanticsLabel('Go off the record'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'switching on shows it in transcript and graph views, with the '
      'mid-session copy', (tester) async {
    await _pumpScreen(tester, saved: true);

    await tester.tap(find.byKey(const Key('offTheRecordToggle')));
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byKey(const Key('offTheRecordIndicator')), findsOneWidget);
    expect(find.text('Off the record'), findsOneWidget);
    // Indicator and the toast both say it plainly.
    expect(find.text(midSession), findsWidgets);
    expect(find.bySemanticsLabel('Back on the record'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.hub_outlined));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const Key('offTheRecordIndicator')), findsOneWidget,
        reason: 'still shown over the graph');

    // And back on the record: gone, with a plain note.
    await tester.tap(find.byKey(const Key('offTheRecordToggle')));
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byKey(const Key('offTheRecordIndicator')), findsNothing);
    expect(find.text(onTheRecordNote), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('quiet mode\'s note sits clear of the indicator', (tester) async {
    await _pumpScreen(tester, saved: true, quietSilenced: true);
    await tester.tap(find.byKey(const Key('offTheRecordToggle')));
    await tester.pump(const Duration(milliseconds: 16));

    final indicator =
        tester.getRect(find.byKey(const Key('offTheRecordIndicator')));
    final note = tester.getRect(find.byKey(const Key('quietModeNote')));
    expect(note.overlaps(indicator), isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with nothing saved yet it makes no claim about earlier turns',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: LumenTheme.light(),
      home: const Scaffold(body: OffTheRecordIndicator(earlierSaved: false)),
    ));
    expect(find.text('Nothing in this conversation is saved.'), findsOneWidget);
    expect(find.text(midSession), findsNothing);
  });

  testWidgets('the top bar toggle reflects its state and fires',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      theme: LumenTheme.light(),
      home: Scaffold(
        body: JournalTopBar(
          entityCount: 1,
          relationCount: 0,
          offTheRecord: true,
          onOffTheRecordTap: () => taps++,
        ),
      ),
    ));
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    await tester.tap(find.byKey(const Key('offTheRecordToggle')));
    expect(taps, 1);
  });
}
