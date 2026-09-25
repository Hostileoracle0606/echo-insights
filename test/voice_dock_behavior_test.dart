// Dynamic-island (VoiceDock) behavior: verifies the dock reacts to its props —
// mic/split/mute taps fire their callbacks, the mute icon reflects state, and
// the split-screen morph surfaces the conversation as bubbles.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/upsert_activity.dart';
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/theme/lumen_theme.dart';

Future<void> _pump(
  WidgetTester tester,
  VoiceDock dock, {
  Size surface = const Size(402, 874),
}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: dock),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
}

// Let morphs finish without pumpAndSettle (the pulse clock repeats forever).
Future<void> _run(WidgetTester tester, {int frames = 60}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('tapping the mic fires onMicTap', (tester) async {
    var taps = 0;
    await _pump(tester, VoiceDock(mode: DockMode.idle, onMicTap: () => taps++));
    await tester.tap(find.byIcon(Icons.mic));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping the split toggle fires onToggleSplit', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.idle,
        onMicTap: () {},
        onToggleSplit: () => taps++,
      ),
    );
    await tester.tap(find.byIcon(Icons.splitscreen));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('volume reflects mute state and fires onMuteTap', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.idle,
        muted: false,
        onMicTap: () {},
        onMuteTap: () => taps++,
      ),
    );
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
    expect(find.byIcon(Icons.volume_off), findsNothing);
    await tester.tap(find.byIcon(Icons.volume_up));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a muted dock shows the muted icon', (tester) async {
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.listening,
        muted: true,
        onMicTap: () {},
        onMuteTap: () {},
      ),
    );
    expect(find.byIcon(Icons.volume_off), findsOneWidget);
    expect(find.byIcon(Icons.volume_up), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('expanded dock surfaces the conversation as bubbles',
      (tester) async {
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.listening,
        expanded: true,
        turns: const [
          DockTurn(DockSpeaker.you, 'Had coffee with Maya.'),
          DockTurn(DockSpeaker.lumen, 'When was the Atlas launch?'),
        ],
        onMicTap: () {},
      ),
    );
    // Let the (repeating-pulse) dock lay out; don't pumpAndSettle.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('Had coffee with Maya.'), findsOneWidget);
    expect(find.text('When was the Atlas launch?'), findsOneWidget);
    // The pinned controls remain reachable while expanded.
    expect(find.byIcon(Icons.mic), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('collapsed dock hides transcript turns', (tester) async {
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.idle,
        turns: const [DockTurn(DockSpeaker.you, 'Hidden while collapsed')],
        onMicTap: () {},
      ),
    );
    expect(find.text('Hidden while collapsed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  group('split pane transcript', () {
    testWidgets('no stale "you" bubble once Lumen has answered',
        (tester) async {
      // Regression: the old pane re-added the last user interim as a pending
      // bubble whenever Lumen's reply was the last row.
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          expanded: true,
          turns: const [
            DockTurn(DockSpeaker.you, 'I met Priya at the gym.'),
            DockTurn(DockSpeaker.lumen, 'How long has she climbed?'),
          ],
          liveUser: 'I met Priya at the gym',
          onMicTap: () {},
        ),
      );
      await _run(tester, frames: 40);
      expect(find.text('I met Priya at the gym.'), findsOneWidget);
      expect(find.text('I met Priya at the gym'), findsNothing,
          reason: 'the pane renders only the rows it is given');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('rows render in the order given, pending ones faded',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.speaking,
          expanded: true,
          turns: const [
            DockTurn(DockSpeaker.you, 'I met Priya', pending: true),
            DockTurn(DockSpeaker.lumen, 'How lovely', pending: true),
          ],
          onMicTap: () {},
        ),
      );
      await _run(tester, frames: 40);
      final you = tester.getTopLeft(find.text('I met Priya'));
      final lumen = tester.getTopLeft(find.text('How lovely'));
      expect(you.dy, lessThan(lumen.dy), reason: 'spoken order is kept');
      final fade = tester.widget<Opacity>(
        find.ancestor(of: find.text('I met Priya'), matching: find.byType(Opacity)).first,
      );
      expect(fade.opacity, lessThan(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a pending row firms up in place when it finalizes',
        (tester) async {
      VoiceDock dock({required bool pending}) => VoiceDock(
            mode: DockMode.listening,
            expanded: true,
            turns: [
              DockTurn(DockSpeaker.you, 'I met Priya.', pending: pending),
              const DockTurn(DockSpeaker.lumen, 'How lovely.'),
            ],
            onMicTap: () {},
          );
      await _pump(tester, dock(pending: true));
      await _run(tester, frames: 40);
      final before = tester.getTopLeft(find.text('I met Priya.'));

      await tester.pumpWidget(MaterialApp(
        theme: LumenTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: dock(pending: false),
          ),
        ),
      ));
      await _run(tester, frames: 10);
      expect(find.text('I met Priya.'), findsOneWidget);
      expect(tester.getTopLeft(find.text('I met Priya.')), before);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('rest pill (web Dynamic Island)', () {
    testWidgets('idle pill shows no labels and no drawer', (tester) async {
      await _pump(tester, VoiceDock(mode: DockMode.idle, onMicTap: () {}));
      await _run(tester);
      expect(find.text('YOU'), findsNothing);
      expect(find.text('LISTENING'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('listening labels the flanks and opens the drawer on speech',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          liveUser: 'I met Priya at the climbing gym',
          onMicTap: () {},
        ),
      );
      await _run(tester);
      expect(find.text('YOU'), findsOneWidget);
      expect(find.text('LISTENING'), findsOneWidget);
      expect(find.text('I met Priya at the climbing gym'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('connecting reads as You / Connecting', (tester) async {
      await _pump(tester, VoiceDock(mode: DockMode.thinking, onMicTap: () {}));
      await _run(tester);
      expect(find.text('YOU'), findsOneWidget);
      expect(find.text('CONNECTING'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('speaking shows Lumen\'s streaming words', (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.speaking,
          liveAgent: 'That is a big moment for her.',
          onMicTap: () {},
        ),
      );
      await _run(tester);
      expect(find.text('LUMEN'), findsOneWidget);
      expect(find.text('SPEAKING'), findsOneWidget);
      expect(find.text('That is a big moment for her.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('extraction while idle reads as Mapping', (tester) async {
      await _pump(
        tester,
        VoiceDock(mode: DockMode.idle, extracting: true, onMicTap: () {}),
      );
      await _run(tester);
      expect(find.text('MAPPING'), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('mic stays on screen centre when there is room',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          liveUser: 'Almost a month',
          onMicTap: () {},
        ),
        surface: const Size(820, 1180),
      );
      await _run(tester);
      final mic = tester.getCenter(find.byIcon(Icons.mic));
      expect(mic.dx, moreOrLessEquals(820 / 2, epsilon: 0.5));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the shift never pushes the pill into the 16pt margin',
        (tester) async {
      // "YOU" vs "LISTENING" wants a rightward shift; on a phone the drawer's
      // 340pt minimum leaves too little room to honour it fully.
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          liveUser: 'Maya said the Atlas demo finally feels real',
          onMicTap: () {},
        ),
      );
      await _run(tester);
      final pill = tester.getRect(
        find
            .ancestor(of: find.byIcon(Icons.mic), matching: find.byType(SizedBox))
            .last,
      );
      expect(pill.left, greaterThanOrEqualTo(16 - 0.5));
      expect(pill.right, lessThanOrEqualTo(402 - 16 + 0.5));
      // The cap engaged: the pill leans right only until its edge meets the
      // margin, and the mic gives up exact centring instead of the margin.
      expect(pill.right, moreOrLessEquals(402 - 16, epsilon: 0.5));
      final mic = tester.getCenter(find.byIcon(Icons.mic));
      expect(mic.dx, lessThan(402 / 2));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an upsert shows the chip above the dock', (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          activity: const UpsertActivity(
            id: 1,
            entityNames: ['Priya', 'Climbing gym'],
            insertedEntities: 2,
            updatedEntities: 0,
            createdRelations: 1,
          ),
          onMicTap: () {},
        ),
      );
      await _run(tester, frames: 90);
      expect(find.text('UPSERTING'), findsOneWidget);
      expect(find.text('Priya'), findsOneWidget);
      expect(find.text('2 new · 0 refreshed · 1 links'), findsOneWidget);
      final chip = tester.getCenter(find.text('UPSERTING'));
      final mic = tester.getCenter(find.byIcon(Icons.mic));
      expect(chip.dy, lessThan(mic.dy));
      await tester.pumpWidget(const SizedBox());
    });
  });
}
