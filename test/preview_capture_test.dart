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
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/graph_legend.dart';

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
    // where the goo blobs bulge; don't pumpAndSettle (it never settles).
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
const _demoTurns = <DockTurn>[
  DockTurn(DockSpeaker.you, 'Had coffee with Maya about the Atlas launch timeline.'),
  DockTurn(DockSpeaker.lumen,
      'When did the Atlas launch slip — was that around the Q3 review?'),
  DockTurn(DockSpeaker.you,
      "Yeah, Q3. Timeline's tight but Maya's relieved it finally feels real."),
  DockTurn(DockSpeaker.lumen,
      "Got it. I've linked Maya to Atlas and noted the relief around Q3."),
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
              ),
            ),
          ),
        ),
      ),
    );
  });

  testWidgets('VoiceDock idle', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-idle',
      width: 360,
      height: 150,
      child: Center(
        child: VoiceDock(mode: DockMode.idle, onMicTap: () {}),
      ),
    );
  });

  // Collapsed voice-active dock: just the living goo pill now — the transcript
  // moved into the split panel, so there's no inline drawer anymore.
  testWidgets('VoiceDock listening', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-listening',
      width: 320,
      height: 130,
      settle: false,
      child: Center(
        child: VoiceDock(mode: DockMode.listening, onMicTap: () {}),
      ),
    );
  });

  // Same goo silhouette as listening, but Lumen is talking rather than
  // recording: the amber mic-pulse ring is absent (compare to "listening").
  testWidgets('VoiceDock speaking', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-speaking',
      width: 320,
      height: 130,
      settle: false,
      child: Center(
        child: VoiceDock(mode: DockMode.speaking, onMicTap: () {}),
      ),
    );
  });

  // Connecting: static paper pill (like idle), but the mic fill breathes a
  // slow, dim pulse — "booting up," distinct from both idle (static) and
  // listening/speaking (living goo).
  testWidgets('VoiceDock thinking', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-thinking',
      width: 320,
      height: 130,
      settle: false,
      child: Center(
        child: VoiceDock(mode: DockMode.thinking, onMicTap: () {}),
      ),
    );
  });

  // The split-screen panel: the dock morphed open, ChatGPT-style transcript
  // above the pinned controls, the in-flight line riding at the bottom.
  testWidgets('VoiceDock expanded', (tester) async {
    await _capture(
      tester,
      name: 'voice-dock-expanded',
      width: 402,
      height: 720,
      settle: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(402, 874)),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: VoiceDock(
              mode: DockMode.listening,
              expanded: true,
              turns: _demoTurns,
              liveUser: 'and Maya wants Lisbon on the roadmap for the trip.',
              onMicTap: () {},
            ),
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

  // The split-screen open, composed the way the stitch will arrange it: warm
  // graph in the top half, transcript panel filling the bottom, the pill's
  // split toggle engaged. Built locally (not the real JournalScreen) since the
  // parent wiring is the next, separate pass.
  testWidgets('Split screen in context', (tester) async {
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
                            expanded: true,
                            turns: _demoTurns,
                            liveUser:
                                'and Maya wants Lisbon on the roadmap for the trip.',
                            onMicTap: () {},
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
    await _writeBoundaryPng(tester, key, 'split-screen', pixelRatio: 2);
    await tester.pumpWidget(const SizedBox());
  });
}
