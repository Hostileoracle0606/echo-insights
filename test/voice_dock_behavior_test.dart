// VoiceDock (pill E) behavior: the dock reacts to its props — mic, view,
// mute and end taps fire their callbacks, the speaker chips show who holds
// the floor, and the drawer carries in-flight words in graph view only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/entity_highlighter.dart';
import 'package:lumen/models/entity.dart';
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

  group('view switch', () {
    testWidgets('the transcript button asks for the transcript view',
        (tester) async {
      final asked = <JournalView>[];
      await _pump(
        tester,
        VoiceDock(onMicTap: () {}, onViewChanged: asked.add),
      );
      await tester.tap(find.byIcon(Icons.article_outlined));
      // Already on the graph: tapping it again is a no-op.
      await tester.tap(find.byIcon(Icons.hub_outlined));
      expect(asked, [JournalView.transcript]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the active view is marked selected', (tester) async {
      await _pump(
        tester,
        VoiceDock(
          view: JournalView.transcript,
          onMicTap: () {},
          onViewChanged: (_) {},
        ),
      );
      bool selected(String label) => tester
          .widget<Semantics>(find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.label == label))
          .properties
          .selected!;
      expect(selected('Transcript view'), isTrue);
      expect(selected('Graph view'), isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the mic sits on the dock centre line', (tester) async {
      for (final width in [402.0, 820.0]) {
        await _pump(
          tester,
          VoiceDock(mode: DockMode.listening, onMicTap: () {}),
          surface: Size(width, 874),
        );
        final mic = tester.getCenter(find.byIcon(Icons.mic));
        expect(mic.dx, moreOrLessEquals(width / 2, epsilon: 0.5));
      }
      await tester.pumpWidget(const SizedBox());
    });
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

  testWidgets('end fires onEndTap, and is inert without a session',
      (tester) async {
    var ends = 0;
    await _pump(tester, VoiceDock(onMicTap: () {}));
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await _pump(
      tester,
      VoiceDock(
        mode: DockMode.listening,
        onMicTap: () {},
        onEndTap: () => ends++,
      ),
    );
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    expect(ends, 1);
    await tester.pumpWidget(const SizedBox());
  });

  group('speaker chips', () {
    testWidgets('idle: both chips at rest, no status', (tester) async {
      await _pump(tester, VoiceDock(mode: DockMode.idle, onMicTap: () {}));
      await _run(tester);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Lumen'), findsOneWidget);
      for (final s in ['Listening', 'Speaking', 'Connecting', 'Mapping']) {
        expect(find.text(s), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('listening lights You and opens the drawer on speech',
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
      expect(find.text('Listening'), findsOneWidget);
      expect(find.text('I met Priya at the climbing gym'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('connecting reads as You · Connecting', (tester) async {
      await _pump(tester, VoiceDock(mode: DockMode.thinking, onMicTap: () {}));
      await _run(tester);
      expect(find.text('Connecting'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('speaking lights Lumen with its streaming words',
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
      expect(find.text('Speaking'), findsOneWidget);
      expect(find.text('Listening'), findsNothing);
      expect(find.text('That is a big moment for her.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('extraction while idle reads as Mapping', (tester) async {
      await _pump(
        tester,
        VoiceDock(mode: DockMode.idle, extracting: true, onMicTap: () {}),
      );
      await _run(tester);
      expect(find.text('Mapping'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('drawer', () {
    testWidgets('stays shut in transcript view — the page is the transcript',
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

    testWidgets('marks known entities in their graph colour', (tester) async {
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
      expect(find.text('Connecting'), findsOneWidget);
      expect(find.text('Listening'), findsNothing);
      // The one "Connecting" is Lumen's: it sits right of the mic.
      expect(
        tester.getCenter(find.text('Connecting')).dx,
        greaterThan(tester.getCenter(find.byIcon(Icons.mic)).dx),
      );
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
      expect(find.text('Connecting'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
