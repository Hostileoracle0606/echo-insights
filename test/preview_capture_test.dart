// Dev tool (not an assertion suite): renders Cycle-A journal widgets in
// isolation on LumenTheme.light() with the real bundled fonts and writes a PNG
// per widget to docs/assets/, for per-widget visual review before stitching.
// Run: flutter test test/preview_capture_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/entity_highlighter.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/notebook.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/providers/auth_provider.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/notebooks_provider.dart';
import 'package:lumen/providers/session_provider.dart';
import 'package:lumen/screens/dashboard/dashboard_screen.dart';
import 'package:lumen/screens/journal/graph_canvas.dart';
import 'package:lumen/screens/journal/graph_drawer.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/screens/journal/journal_top_bar.dart';
import 'package:lumen/screens/journal/transcript_page.dart';
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/context_tile.dart';
import 'package:lumen/widgets/graph_legend.dart';
import 'package:lumen/widgets/mode_header.dart';
import 'package:lumen/widgets/result_card.dart';

Future<void> _loadFont(String family, String path) async {
  final bytes = await File(path).readAsBytes();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
}

// Reads a RepaintBoundary back as a PNG and writes it to docs/assets.
// toImage resolves on the engine's raster thread — real async work the
// FakeAsync test zone won't pump. Without runAsync the await stalls until
// the 10-minute test timeout fires, so the readback runs on a real-async
// island. Callers unmount afterward so any live ticker disposes.
Future<void> _writeBoundaryPng(
  WidgetTester tester,
  GlobalKey key,
  String name, {
  double pixelRatio = 3,
}) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data;
  });
  final file = File('docs/assets/preview-$name.png');
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
  // ignore: avoid_print
  print('WROTE ${file.absolute.path}');
}

Future<void> _capture(
  WidgetTester tester, {
  required String name,
  required double width,
  required double height,
  required Widget child,
  bool settle = true,
  int frames = 0,
  Future<void> Function(WidgetTester)? interact,
}) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      // Scaffold supplies Material + the theme's Inter DefaultTextStyle, so
      // unspecified-family text resolves to Inter instead of the test's Ahem.
      home: Scaffold(
        body: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: width,
              height: height,
              // Paint the paper background inside the captured boundary so the
              // PNG isn't transparent where the widget doesn't cover.
              child: Builder(
                builder: (c) => ColoredBox(
                  color: Theme.of(c).scaffoldBackgroundColor,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (interact != null) await interact(tester);
  if (frames > 0) {
    // Continuously-ticking widget (e.g. the graph force sim): step N frames so
    // the layout settles, then capture. pumpAndSettle would never return.
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  } else if (settle) {
    await tester.pumpAndSettle();
  } else {
    // Animated widget (repeating controller): advance to a mid-cycle frame
    // where the mic ring is mid-pulse; don't pumpAndSettle (it never settles).
    await tester.pump(const Duration(milliseconds: 1100));
  }
  await _writeBoundaryPng(tester, key, name);
  // Unmount so any running ticker disposes before the test ends.
  if (!settle || frames > 0) await tester.pumpWidget(const SizedBox());
}

class _SeededJournal extends JournalNotifier {
  _SeededJournal(this._seed);
  final JournalState _seed;
  @override
  JournalState build() => _seed;
}

JournalState _graphState() {
  final now = DateTime(2026, 4, 26, 14, 0);
  Entity e(String id, String name, EntityType type, int mentions) => Entity(
        id: id,
        name: name,
        type: type,
        metadata: const {},
        mentions: mentions,
        firstSeen: now,
        lastSeen: now,
      );
  Relation r(String s, String t, String label) => Relation(
        id: '${s}_${label}_$t',
        source: s,
        target: t,
        label: label,
        metadata: const {},
        createdAt: now,
      );
  final entities = <String, Entity>{
    'maya': e('maya', 'Maya', EntityType.person, 7),
    'atlas': e('atlas', 'Atlas', EntityType.project, 9),
    'q3': e('q3', 'Q3 review', EntityType.event, 4),
    'lisbon': e('lisbon', 'Lisbon', EntityType.place, 3),
    'timeline': e('timeline', 'timeline', EntityType.concept, 5),
    'acme': e('acme', 'Acme', EntityType.organization, 2),
    'joy': e('joy', 'relief', EntityType.emotion, 2),
  };
  final relations = <Relation>[
    r('maya', 'atlas', 'works_on'),
    r('atlas', 'q3', 'reviewed_at'),
    r('maya', 'lisbon', 'based_in'),
    r('atlas', 'timeline', 'tracked_by'),
    r('acme', 'atlas', 'owns'),
    r('q3', 'joy', 'evokes'),
  ];
  return JournalState(
    entries: const [],
    entities: entities,
    relations: {for (final rel in relations) rel.id: rel},
    followUps: const [],
  );
}

// A short rolling conversation whose entities match the seeded graph.
final _demoTurns = <TranscriptTurn>[
  TranscriptTurn(
      DockSpeaker.you, 'Had coffee with Maya about the Atlas launch timeline.',
      id: 'd0', at: DateTime(2026, 9, 25, 9, 41)),
  TranscriptTurn(DockSpeaker.lumen,
      'When did the Atlas launch slip — was that around the Q3 review?',
      id: 'd1', at: DateTime(2026, 9, 25, 9, 42)),
  TranscriptTurn(DockSpeaker.you,
      "Yeah, Q3. Timeline's tight but Maya's relieved it finally feels real.",
      id: 'd2', at: DateTime(2026, 9, 25, 9, 42)),
  TranscriptTurn(DockSpeaker.lumen,
      "Got it. I've linked Maya to Atlas and noted the relief around Q3.",
      id: 'd3', at: DateTime(2026, 9, 25, 9, 43)),
];

const _demoTerms = [
  HighlightTerm('Maya', EntityType.person),
  HighlightTerm('Atlas launch', EntityType.project),
  HighlightTerm('Atlas', EntityType.project),
  HighlightTerm('Lisbon', EntityType.place),
  HighlightTerm('relief', EntityType.emotion),
  HighlightTerm('Q3 review', EntityType.event),
];

// A spread of notebooks across the time groups for the dashboard capture.
List<Notebook> _demoNotebooks() {
  final now = DateTime.now();
  Notebook nb(
    String id,
    String title,
    Duration ago,
    int entities,
    String summary, {
    bool live = false,
  }) {
    final started = now.subtract(ago);
    return Notebook(
      id: id,
      userId: 'demo',
      title: title,
      titleSource: 'ai',
      startedAt: started,
      endedAt: live ? null : started.add(const Duration(minutes: 20)),
      entityCount: entities,
      summary: summary,
      createdAt: started,
      updatedAt: started,
    );
  }

  return [
    nb('1', 'Atlas launch & Maya', const Duration(minutes: 5), 8,
        "Mapped the Q3 timeline and how Maya's feeling about the slip.",
        live: true),
    nb('2', 'Lisbon trip planning', const Duration(days: 2), 11,
        'Booked the dates, roughed out the roadmap with the team.'),
    nb('3', 'Reading notes', const Duration(days: 4), 6,
        'Threads between the Calvino essays and the Acme deck.'),
    nb('4', 'First brain-dump', const Duration(days: 40), 16,
        'Everything on my mind the night before the offsite.'),
  ];
}

// A bottom slice of a 402pt phone: the pill sizes from the screen width.
Widget _dockSlice(VoiceDock dock) => MediaQuery(
      data: const MediaQueryData(size: Size(402, 874)),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(padding: const EdgeInsets.only(bottom: 16), child: dock),
      ),
    );

// LM-09 copy, from the prototype's Close and Prep screens.
const _ciWin =
    'Cut CI build time 41% (22 → 13 min) by fixing cache keys, with Priya.';

// A card-width column on paper, pinned to the top, for the LM-09 pieces.
Widget _cardSlot(Widget child) => Padding(
      padding: const EdgeInsets.all(16),
      child: Align(alignment: Alignment.topCenter, child: child),
    );

void main() {
  setUpAll(() async {
    await _loadFont('Inter', 'assets/fonts/Inter.ttf');
    await _loadFont('Fraunces', 'assets/fonts/Fraunces.ttf');
    // Material icon glyphs (otherwise render as tofu boxes in tests). Path is
    // the local Flutter SDK cache; skip gracefully if it moves.
    const materialIcons =
        '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf';
    if (File(materialIcons).existsSync()) {
      await _loadFont('MaterialIcons', materialIcons);
    }
  });

  testWidgets('JournalTopBar', (tester) async {
    await _capture(
      tester,
      name: 'journal-top-bar',
      width: 402,
      height: 150,
      // Paper page slice so the bar reads in context. Split toggle engaged so
      // the ink-filled chip (the open-transcript state) is visible.
      child: Builder(
        builder: (context) => ColoredBox(
          color: Theme.of(context).scaffoldBackgroundColor,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
            child: Align(
              alignment: Alignment.topCenter,
              child: JournalTopBar(
                entityCount: 8,
                relationCount: 6,
                onMenuTap: () {},
                onMuteTap: () {},
                onEndTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
  });

  // The pill at rest: Type · Talk · View, hugging its three buttons. Type is
  // shown here for design review; the journal passes no onTypeTap until LM-12.
  testWidgets('VoiceDock idle', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-idle',
      width: 402,
      height: 120,
      child: _dockSlice(
        VoiceDock(
          mode: DockMode.idle,
          onMicTap: () {},
          onTypeTap: () {},
          onViewChanged: (_) {},
        ),
      ),
    );
  });

  // Listening, no words yet: "You · Listening" above the row and the amber mic
  // ring pulsing.
  testWidgets('VoiceDock listening', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-listening',
      width: 402,
      height: 160,
      settle: false,
      child: _dockSlice(
        VoiceDock(
          mode: DockMode.listening,
          onMicTap: () {},
          onTypeTap: () {},
          onViewChanged: (_) {},
        ),
      ),
    );
  });

  // Lumen is talking rather than recording: "Lumen · Speaking" in sage with its
  // streaming words, and the amber mic-pulse ring absent.
  testWidgets('VoiceDock speaking', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-speaking',
      width: 402,
      height: 220,
      settle: false,
      frames: 40,
      child: _dockSlice(
        VoiceDock(
          mode: DockMode.speaking,
          terms: _demoTerms,
          liveAgent: 'What does Maya think Lisbon changes about the launch?',
          onMicTap: () {},
          onTypeTap: () {},
          onViewChanged: (_) {},
        ),
      ),
    );
  });

  // Connecting: "You · Connecting" and the mic fill breathes a slow, dim
  // pulse — "booting up," distinct from idle (static) and listening (ring).
  testWidgets('VoiceDock thinking', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-thinking',
      width: 402,
      height: 160,
      settle: false,
      child: _dockSlice(
        VoiceDock(
          mode: DockMode.thinking,
          onMicTap: () {},
          onTypeTap: () {},
          onViewChanged: (_) {},
        ),
      ),
    );
  });

  // Graph view, someone speaking: the live words ride in the pill under the
  // label, entities marked in their graph colours.
  testWidgets('VoiceDock drawer', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-drawer',
      width: 402,
      height: 220,
      settle: false,
      frames: 40,
      child: _dockSlice(
        VoiceDock(
          mode: DockMode.listening,
          terms: _demoTerms,
          liveUser: 'and Maya wants Lisbon on the roadmap for the trip.',
          onMicTap: () {},
          onTypeTap: () {},
          onViewChanged: (_) {},
        ),
      ),
    );
  });

  // Transcript view: the whole conversation as a rolling page, the dock
  // floating over it with the page button marked.
  testWidgets('TranscriptPage', (tester) async {
    await _capture(
      tester,
      name: 'transcript-page',
      width: 402,
      height: 874,
      settle: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(402, 874)),
        child: ColoredBox(
          color: LumenColors.light.paper,
          child: Stack(
            fit: StackFit.expand,
            children: [
              TranscriptPage(
                turns: _demoTurns,
                terms: _demoTerms,
                topInset: 60,
                bottomInset: 164,
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: VoiceDock(
                    mode: DockMode.speaking,
                    view: JournalView.transcript,
                    onMicTap: () {},
                    onViewChanged: (_) {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  });

  testWidgets('GraphCanvas', (tester) async {
    await _capture(
      tester,
      name: 'graph-canvas',
      width: 402,
      height: 520,
      frames: 130,
      child: GraphCanvas(state: _graphState()),
    );
  });

  testWidgets('GraphLegend', (tester) async {
    await _capture(
      tester,
      name: 'graph-legend',
      width: 240,
      height: 380,
      interact: (t) async {
        await t.tap(find.byTooltip('Expand legend'));
        await t.pumpAndSettle();
      },
      child: const Align(
        alignment: Alignment.topRight,
        child: Padding(padding: EdgeInsets.all(12), child: GraphLegend()),
      ),
    );
  });

  // The graph sidepane: entities grouped into sections by type, opened from the
  // top-bar hamburger. Seeded over a real journal provider.
  testWidgets('GraphDrawer', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          journalProvider.overrideWith(() => _SeededJournal(_graphState())),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 304,
              height: 720,
              child: GraphDrawer(onEntityTap: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _writeBoundaryPng(tester, key, 'graph-drawer', pixelRatio: 2);
    await tester.pumpWidget(const SizedBox());
  });

  // The notebooks dashboard: welcome hero + time-grouped notebook cards.
  testWidgets('Dashboard', (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notebooksProvider.overrideWith((ref) => _demoNotebooks()),
          displayNameProvider.overrideWithValue('Trinab'),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: RepaintBoundary(
            key: key,
            child: const SizedBox(
              width: 402,
              height: 874,
              child: DashboardScreen(),
            ),
          ),
        ),
      ),
    );
    // The hero pulse repeats forever; pump past the ~1.3s intro, then capture
    // mid-pulse (pumpAndSettle would never return).
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _writeBoundaryPng(tester, key, 'dashboard', pixelRatio: 2);
    await tester.pumpWidget(const SizedBox());
  });

  // The full integrated screen (real JournalScreen with seeded providers),
  // at iPhone-17 logical size — proof the stitch produced the paper journal.
  testWidgets('JournalScreen integrated', (tester) async {
    // Phone-portrait surface, else the default 800x600 test window's tight
    // constraints squash the SizedBox into landscape.
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          journalProvider.overrideWith(() => _SeededJournal(_graphState())),
          sessionStatusProvider.overrideWithValue(SessionStatus.live),
          liveUserTextProvider.overrideWithValue(
            '…had coffee with Maya about the Atlas launch timeline.',
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: RepaintBoundary(
            key: key,
            child: const SizedBox(
              width: 402,
              height: 874,
              child: JournalScreen(),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 130; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _writeBoundaryPng(tester, key, 'journal-screen', pixelRatio: 2);
    await tester.pumpWidget(const SizedBox());
  });

  // Graph view in context: the warm graph behind, the pill open with the
  // in-flight words under its status label.
  testWidgets('Graph with drawer in context', (tester) async {
    // Phone-portrait surface so the SizedBox isn't squashed by the default
    // 800x600 test window (tight constraints would otherwise win).
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: LumenTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(402, 874)),
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 402,
              height: 874,
              child: Scaffold(
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    GraphCanvas(state: _graphState()),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                        child: JournalTopBar(
                          entityCount: 8,
                          relationCount: 6,
                          onMenuTap: () {},
                          onMuteTap: () {},
                          onEndTap: () {},
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 28),
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: VoiceDock(
                            mode: DockMode.listening,
                            terms: _demoTerms,
                            liveUser:
                                'and Maya wants Lisbon on the roadmap for the trip.',
                            onMicTap: () {},
                            onViewChanged: (_) {},
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 130; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _writeBoundaryPng(tester, key, 'graph-with-drawer', pixelRatio: 2);
    await tester.pumpWidget(const SizedBox());
  });

  // LM-09: the raised result card with its ink-badged hero on highlight.
  testWidgets('ResultCard with hero', (tester) async {
    await _capture(
      tester,
      name: 'result-card-hero',
      width: 402,
      height: 470,
      child: _cardSlot(
        ResultCard(
          eyebrow: 'This week · 3 wins',
          onExpand: () {},
          expandLabel: 'Open your full review brief',
          hero: const ResultRow(
            badge: ResultBadge.check(),
            label: 'Top win',
            text: _ciWin,
            meta: 'Tuesday · with Priya',
          ),
          rows: const [
            ResultRow(
              badge: ResultBadge.check(),
              text: 'Unblocked the Atlas handoff with Maya',
            ),
            ResultRow(
              badge: ResultBadge.check(),
              text: 'Said no to the Friday offsite prep',
              meta: 'Thursday',
            ),
          ],
          footerNote: '41 wins in your brief',
          footerActionLabel: 'Copy',
          onFooterAction: () {},
        ),
      ),
    );
  });

  // LM-09: the same card without a hero — the prep brief's numbered list.
  testWidgets('ResultCard without hero', (tester) async {
    await _capture(
      tester,
      name: 'result-card-prep',
      width: 402,
      height: 300,
      child: _cardSlot(
        ResultCard(
          eyebrow: 'Bring these up.',
          onExpand: () {},
          expandLabel: 'Open your prep brief',
          rows: const [
            ResultRow(
              badge: ResultBadge.number(1),
              text: 'The CI win: 22 → 13 min, with Priya',
            ),
            ResultRow(
              badge: ResultBadge.number(2),
              text: 'Who owns the Atlas handoff after the demo?',
            ),
            ResultRow(
              badge: ResultBadge.number(3),
              text: 'Your Q4 growth goal',
              meta: 'You set it in June',
            ),
          ],
        ),
      ),
    );
  });

  // LM-09: flat context tile and the "Lumen will remember" list.
  testWidgets('ContextTile and ContextList', (tester) async {
    await _capture(
      tester,
      name: 'context-tiles',
      width: 402,
      height: 340,
      child: _cardSlot(
        Column(
          children: [
            const ContextTile(
              icon: Icons.history,
              eyebrow: 'Since last time',
              body: 'You wanted Priya to get credit for the cache-key fix '
                  'in your review.',
            ),
            const SizedBox(height: 16),
            ContextList(
              eyebrow: 'Lumen will remember',
              items: const [
                ContextItem(title: 'Priya', note: 'paired on the cache keys'),
                ContextItem(title: 'CI build time', note: '22 → 13 min'),
                ContextItem(
                    title: 'Ask Priya about the Q4 rollout', open: true),
              ],
              onRemove: (_) {},
            ),
          ],
        ),
      ),
    );
  });

  // LM-09: mode header with a stand-in trailing pill, at 375pt with a long
  // title so the ellipsis shows.
  testWidgets('ModeHeader', (tester) async {
    Widget pill(BuildContext context) {
      final colors = context.lumenColors;
      return Container(
        width: 150,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: colors.border),
        ),
        child: Text('12:04 · End', style: TextStyle(color: colors.ink)),
      );
    }

    await _capture(
      tester,
      name: 'mode-header',
      width: 375,
      height: 150,
      child: Builder(
        builder: (context) => Column(
          children: [
            ModeHeader(
              title: 'Weekly debrief',
              onBack: () {},
              trailing: pill(context),
            ),
            ModeHeader(
              title: 'Prepare for your one-on-one with Priya',
              onBack: () {},
              trailing: pill(context),
            ),
          ],
        ),
      ),
    );
  });
}
