// VoiceDock (the pill) behavior: the pill reacts to its props — Type, mic
// and View taps fire their callbacks, the status label shows who holds the
// floor, the live words ride in the pill in graph view only, and the pill
// widens for the tier and narrows back without moving the mic.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/entity_highlighter.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/upsert_activity.dart';
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/breathing_dots.dart';

Future<void> _pump(
  WidgetTester tester,
  VoiceDock dock, {
  Size surface = const Size(402, 874),
  bool reduceMotion = false,
}) async {
  // The view, not just the surface: the pill sizes from MediaQuery.
  tester.view
    ..physicalSize = surface
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      home: Builder(
        builder: (context) => MediaQuery(
          data:
              MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: dock),
          ),
        ),
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

double _pillWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(VoiceDock.pillKey)).width;

void main() {
  testWidgets('tapping the mic fires onMicTap', (tester) async {
    var taps = 0;
    await _pump(tester, VoiceDock(mode: DockMode.idle, onMicTap: () => taps++));
    await tester.tap(find.bySemanticsLabel('Microphone'));
    expect(taps, 1);
    await tester.pumpWidget(const SizedBox());
  });

  group('Type', () {
    testWidgets('tapping Type fires onTypeTap', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        VoiceDock(onMicTap: () {}, onTypeTap: () => taps++),
      );
      expect(find.bySemanticsLabel('Type instead'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      expect(taps, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without onTypeTap the slot is an empty spacer',
        (tester) async {
      await _pump(tester, VoiceDock(onMicTap: () {}));
      expect(find.byIcon(Icons.keyboard_outlined), findsNothing);
      expect(find.bySemanticsLabel('Type instead'), findsNothing);
      // The spacer keeps the row symmetric: the pill still hugs 184pt.
      expect(_pillWidth(tester), moreOrLessEquals(184));
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a dock mounted with its composer open unmounts cleanly',
      (tester) async {
    // The row (and its mic pulse) never builds while the composer is set.
    await _pump(
      tester,
      VoiceDock(onMicTap: () {}, composer: const SizedBox(height: 60)),
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  group('View toggle', () {
    testWidgets('in graph view it offers the transcript', (tester) async {
      final asked = <JournalView>[];
      await _pump(
        tester,
        VoiceDock(onMicTap: () {}, onViewChanged: asked.add),
      );
      expect(find.byIcon(Icons.hub_outlined), findsNothing);
      expect(find.bySemanticsLabel('Show transcript'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.article_outlined));
      expect(asked, [JournalView.transcript]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('in transcript view it offers the graph', (tester) async {
      final asked = <JournalView>[];
      await _pump(
        tester,
        VoiceDock(
          view: JournalView.transcript,
          onMicTap: () {},
          onViewChanged: asked.add,
        ),
      );
      expect(find.byIcon(Icons.article_outlined), findsNothing);
      expect(find.bySemanticsLabel('Show graph'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.hub_outlined));
      expect(asked, [JournalView.graph]);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the mic sits on the screen centre line', () {
    Future<void> expectCentred(WidgetTester tester, VoiceDock dock) async {
      for (final width in [375.0, 402.0, 820.0]) {
        await _pump(tester, dock, surface: Size(width, 874));
        await _run(tester);
        final mic = tester.getCenter(find.bySemanticsLabel('Microphone'));
        expect(mic.dx, moreOrLessEquals(width / 2, epsilon: 0.5),
            reason: 'at ${width}pt');
      }
      await tester.pumpWidget(const SizedBox());
    }

    testWidgets('at rest, with all three buttons', (tester) async {
      await expectCentred(
        tester,
        VoiceDock(
          mode: DockMode.idle,
          onMicTap: () {},
          onTypeTap: () {},
          onViewChanged: (_) {},
        ),
      );
    });

    testWidgets('at rest, without Type', (tester) async {
      await expectCentred(
        tester,
        VoiceDock(
          mode: DockMode.idle,
          onMicTap: () {},
          onViewChanged: (_) {},
        ),
      );
    });

    testWidgets('with the tier open', (tester) async {
      await expectCentred(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          liveUser: 'I met Priya at the climbing gym',
          onMicTap: () {},
          onViewChanged: (_) {},
        ),
      );
    });

    testWidgets('with the tier open, without Type', (tester) async {
      await expectCentred(
        tester,
        VoiceDock(
          mode: DockMode.speaking,
          liveAgent: 'That is a big moment for her.',
          onMicTap: () {},
          onViewChanged: (_) {},
        ),
      );
    });
  });

  group('width', () {
    testWidgets('at rest the pill hugs its three buttons', (tester) async {
      await _pump(
        tester,
        VoiceDock(onMicTap: () {}, onTypeTap: () {}, onViewChanged: (_) {}),
      );
      expect(_pillWidth(tester), moreOrLessEquals(184));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'widens with the spring when the tier appears, and narrows back',
        (tester) async {
      await _pump(tester, VoiceDock(onMicTap: () {}));
      expect(_pillWidth(tester), moreOrLessEquals(184));

      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          liveUser: 'Coffee with Maya',
          onMicTap: () {},
        ),
      );
      // Mid-spring: on its way out, not there yet.
      final mid = _pillWidth(tester);
      expect(mid, greaterThan(184));
      expect(mid, lessThan(358));
      await _run(tester);
      expect(_pillWidth(tester), moreOrLessEquals(358));

      await _pump(tester, VoiceDock(onMicTap: () {}));
      await _run(tester);
      expect(_pillWidth(tester), moreOrLessEquals(184));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the open tier never exceeds the screen minus 32pt',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(mode: DockMode.listening, onMicTap: () {}),
        surface: const Size(375, 812),
      );
      await _run(tester);
      expect(_pillWidth(tester), moreOrLessEquals(375 - 32));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with reduced motion it resizes at once, no spring',
        (tester) async {
      await _pump(tester, VoiceDock(onMicTap: () {}), reduceMotion: true);
      await _pump(
        tester,
        VoiceDock(mode: DockMode.listening, onMicTap: () {}),
        reduceMotion: true,
      );
      expect(_pillWidth(tester), moreOrLessEquals(358));
      expect(find.text('Listening'), findsOneWidget);

      await _pump(tester, VoiceDock(onMicTap: () {}), reduceMotion: true);
      expect(_pillWidth(tester), moreOrLessEquals(184));
      expect(find.text('Listening'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('composer slot', () {
    testWidgets('a composer replaces the button row', (tester) async {
      await _pump(
        tester,
        VoiceDock(
          onMicTap: () {},
          onTypeTap: () {},
          onViewChanged: (_) {},
          composer: const Text('composer here'),
        ),
      );
      await _run(tester);
      expect(find.text('composer here'), findsOneWidget);
      expect(find.bySemanticsLabel('Microphone'), findsNothing);
      expect(find.byIcon(Icons.keyboard_outlined), findsNothing);
      expect(find.byIcon(Icons.article_outlined), findsNothing);

      // Dropping the composer brings the row back.
      await _pump(
        tester,
        VoiceDock(onMicTap: () {}, onTypeTap: () {}, onViewChanged: (_) {}),
      );
      await _run(tester);
      expect(find.text('composer here'), findsNothing);
      expect(find.bySemanticsLabel('Microphone'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('status label', () {
    testWidgets('idle: no tier, no status', (tester) async {
      await _pump(tester, VoiceDock(mode: DockMode.idle, onMicTap: () {}));
      await _run(tester);
      expect(find.text('You'), findsNothing);
      expect(find.text('Lumen'), findsNothing);
      for (final s in ['Listening', 'Speaking', 'Connecting', 'Mapping']) {
        expect(find.text(s), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the label is a live region for VoiceOver', (tester) async {
      await _pump(tester, VoiceDock(mode: DockMode.listening, onMicTap: () {}));
      await _run(tester);
      final live = find.ancestor(
        of: find.text('Listening'),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.liveRegion == true,
        ),
      );
      expect(live, findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('listening reads You · Listening and shows the words',
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
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Listening'), findsOneWidget);
      expect(find.text('Lumen'), findsNothing);
      expect(find.text('I met Priya at the climbing gym'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('connecting reads as You · Connecting', (tester) async {
      await _pump(tester, VoiceDock(mode: DockMode.thinking, onMicTap: () {}));
      await _run(tester);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Connecting'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('speaking reads Lumen · Speaking with its streaming words',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.speaking,
          liveAgent: 'That is a big moment for her.',
          onMicTap: () {},
        ),
      );
      await _run(tester);
      expect(find.text('Lumen'), findsOneWidget);
      expect(find.text('Speaking'), findsOneWidget);
      expect(find.text('You'), findsNothing);
      expect(find.text('Listening'), findsNothing);
      expect(find.text('That is a big moment for her.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('extraction while idle reads as Lumen · Mapping',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(mode: DockMode.idle, extracting: true, onMicTap: () {}),
      );
      await _run(tester);
      expect(find.text('Lumen'), findsOneWidget);
      expect(find.text('Mapping'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('live words', () {
    testWidgets('stay out of the pill in transcript view — the page has them',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          view: JournalView.transcript,
          liveUser: 'Words that belong on the page',
          onMicTap: () {},
        ),
      );
      await _run(tester);
      expect(find.text('Listening'), findsOneWidget);
      expect(find.text('Words that belong on the page'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('mark known entities in their graph colour', (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          liveUser: 'Coffee with Maya today',
          terms: const [HighlightTerm('Maya', EntityType.person)],
          onMicTap: () {},
        ),
      );
      await _run(tester);
      final text = tester.widget<Text>(find.text('Coffee with Maya today'));
      final spans = (text.textSpan! as TextSpan).children!.cast<TextSpan>();
      final maya = spans.singleWhere((s) => s.text == 'Maya');
      expect(maya.style?.backgroundColor, isNotNull);
      expect(
        spans.where((s) => s.text != 'Maya').every(
              (s) => s.style?.backgroundColor == null,
            ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('an upsert shows the chip above the pill', (tester) async {
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
    final mic = tester.getCenter(find.bySemanticsLabel('Microphone'));
    expect(chip.dy, lessThan(mic.dy));
    await tester.pumpWidget(const SizedBox());
  });

  group('opening phase (Lumen has the floor)', () {
    testWidgets('before Lumen\'s audio: Lumen · Connecting, never You',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.thinking,
          openingInProgress: true,
          onMicTap: () {},
        ),
      );
      await _run(tester);
      expect(find.text('Lumen'), findsOneWidget);
      expect(find.text('Connecting'), findsOneWidget);
      expect(find.text('You'), findsNothing);
      expect(find.text('Listening'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('once the opening plays: Lumen · Speaking with its words',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.speaking,
          openingInProgress: true,
          liveAgent: 'Good to see you again.',
          onMicTap: () {},
        ),
      );
      await _run(tester);
      expect(find.text('Speaking'), findsOneWidget);
      expect(find.text('Good to see you again.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a lull mid-opening still reads as Lumen, not You',
        (tester) async {
      // Network jitter can drain the playback queue between chunks; the
      // opening is still Lumen's turn and the mic is still gated.
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          openingInProgress: true,
          liveAgent: 'Good to see',
          onMicTap: () {},
        ),
      );
      await _run(tester);
      expect(find.text('Listening'), findsNothing);
      expect(find.text('Lumen'), findsOneWidget);
      expect(find.text('Connecting'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('paused and reconnecting', () {
    testWidgets('a paused mic reads "You · Paused" with a muted mic icon',
        (tester) async {
      var taps = 0;
      await _pump(
        tester,
        VoiceDock(mode: DockMode.idle, paused: true, onMicTap: () => taps++),
      );
      await _run(tester);

      expect(find.text('You'), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.byIcon(Icons.mic_off), findsOneWidget);
      await tester.tap(find.byIcon(Icons.mic_off));
      expect(taps, 1, reason: 'the same button resumes');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('paused wins over Mapping: one speaker at a time',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.idle,
          paused: true,
          extracting: true,
          onMicTap: () {},
        ),
      );
      await _run(tester);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.text('Mapping'), findsNothing);
      expect(find.text('Lumen'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a reconnect reads "Lumen · Reconnecting" over listening',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          reconnecting: true,
          onMicTap: () {},
        ),
      );
      await _run(tester);

      expect(find.text('Reconnecting'), findsOneWidget);
      expect(find.text('Listening'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Lumen mulling it over', () {
    testWidgets('the pill gives Lumen the floor, with breathing dots',
        (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.listening,
          awaitingReply: true,
          onMicTap: () {},
        ),
      );
      await _run(tester);

      expect(find.text('Lumen'), findsOneWidget);
      expect(find.text('Mulling it over'), findsOneWidget);
      expect(find.byType(BreathingDots), findsOneWidget);
      expect(find.text('Listening'), findsNothing,
          reason: "the user's turn is over");
    });

    testWidgets('above the composer while typing', (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.idle,
          awaitingReply: true,
          onMicTap: () {},
          composer: const SizedBox(height: 44, width: 300),
        ),
      );
      await _run(tester);

      expect(find.text('Mulling it over'), findsOneWidget);
    });

    testWidgets('Lumen speaking replaces it', (tester) async {
      await _pump(
        tester,
        VoiceDock(
          mode: DockMode.speaking,
          onMicTap: () {},
        ),
      );
      await _run(tester);

      expect(find.text('Speaking'), findsOneWidget);
      expect(find.byType(BreathingDots), findsNothing);
    });
  });
}
