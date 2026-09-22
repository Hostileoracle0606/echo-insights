import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/session_provider.dart';
import 'package:lumen/screens/auth/login_screen.dart';
import 'package:lumen/screens/auth/signup_screen.dart';
import 'package:lumen/screens/journal/graph_canvas.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/screens/journal/journal_top_bar.dart';
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/theme/lumen_theme.dart';

void main() {
  const screen = String.fromEnvironment('SCREEN', defaultValue: 'login');
  runApp(const _PreviewApp(screen: screen));
}

class _PreviewApp extends StatelessWidget {
  final String screen;

  const _PreviewApp({required this.screen});

  @override
  Widget build(BuildContext context) {
    final overrides = switch (screen) {
      'journal' => <Override>[
          journalProvider.overrideWith(_PreviewJournalNotifier.new),
          sessionStatusProvider.overrideWithValue(SessionStatus.live),
          lastTranscriptProvider.overrideWithValue(
            'Maya said the Atlas demo finally feels real, but I still do not know who owns the handoff.',
          ),
        ],
      _ => const <Override>[],
    };

    return ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: LumenTheme.light(),
        home: switch (screen) {
          'signup' => const SignupScreen(),
          'journal' => const JournalScreen(),
          'topbar' => const _WidgetGallery(
              label: 'JournalTopBar',
              child: JournalTopBar(
                entityCount: 24,
                relationCount: 31,
              ),
            ),
          'voicedock' => const _VoiceDockPreview(),
          'graph' => Scaffold(body: GraphCanvas(state: _previewState)),
          _ => const LoginScreen(),
        },
      ),
    );
  }
}

/// Renders a single widget in isolation on the paper theme, pinned to the top
/// of an otherwise empty screen, with a small caption — for per-widget review
/// before the widget is stitched into JournalScreen.
class _WidgetGallery extends StatelessWidget {
  final String label;
  final Widget child;

  const _WidgetGallery({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              child,
              const SizedBox(height: 16),
              Text(
                'preview · $label',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Interactive VoiceDock preview: tap the mic to cycle idle → listening →
/// speaking → thinking, so the living goo silhouette, pulse ring, and drawer
/// morph can be verified live on the simulator.
class _VoiceDockPreview extends StatefulWidget {
  const _VoiceDockPreview();

  @override
  State<_VoiceDockPreview> createState() => _VoiceDockPreviewState();
}

class _VoiceDockPreviewState extends State<_VoiceDockPreview> {
  DockMode _mode = DockMode.idle;
  bool _muted = false;

  static const _transcripts = <DockMode, String>{
    DockMode.listening: '…had coffee with Maya about the Atlas launch timeline.',
    DockMode.speaking: 'When did the Atlas launch slip — was that the Q3 review?',
  };

  void _cycle() {
    setState(() {
      _mode = DockMode.values[(_mode.index + 1) % DockMode.values.length];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 24),
            Text(
              'VoiceDock · ${_mode.name}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'tap the mic to cycle states · tap speaker to toggle mute',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            VoiceDock(
              mode: _mode,
              muted: _muted,
              transcript: _transcripts[_mode],
              onMicTap: _cycle,
              onToggleSplit: () {},
              onMuteTap: () => setState(() => _muted = !_muted),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

class _PreviewJournalNotifier extends JournalNotifier {
  @override
  JournalState build() => _previewState;
}

final _now = DateTime.utc(2026, 6, 14, 10, 30);

Entity _entity(
  String id,
  String name,
  EntityType type, {
  int mentions = 1,
  String? description,
  List<String>? questions,
}) =>
    Entity(
      id: id,
      name: name,
      type: type,
      description: description,
      metadata: const {},
      mentions: mentions,
      firstSeen: _now.subtract(const Duration(days: 12)),
      lastSeen: _now,
      questions: questions,
    );

Relation _relation(String source, String label, String target) => Relation(
      id: '${source}__${label}__$target',
      source: source,
      target: target,
      label: label,
      metadata: const {},
      createdAt: _now,
    );

final _previewRelations = [
  _relation('maya', 'works_on', 'project-atlas'),
  _relation('project-atlas', 'reviewed_at', 'q3-review'),
  _relation('maya', 'lives_near', 'brooklyn'),
  _relation('running', 'helps_with', 'burnout'),
  _relation('ai', 'related_to', 'project-atlas'),
  _relation('q3-review', 'involves', 'sam'),
];

final _previewState = JournalState(
  entries: [
    JournalEntry(
      id: 'e-1',
      text:
          'Maya said the Atlas demo finally feels real, but I still do not know who owns the handoff.',
      createdAt: _now,
      entityIds: const ['maya', 'project-atlas', 'q3-review'],
      relationIds: _previewRelations.map((relation) => relation.id).toList(),
    ),
  ],
  entities: {
    'maya': _entity('maya', 'Maya', EntityType.person, mentions: 7),
    'project-atlas': _entity(
      'project-atlas',
      'Project Atlas',
      EntityType.project,
      mentions: 9,
      description: 'Migration project Maya has been helping unblock.',
      questions: const [
        'Who owns the Atlas handoff after the demo?',
        'What would make the Q3 review feel safe?',
      ],
    ),
    'brooklyn': _entity('brooklyn', 'Brooklyn', EntityType.place, mentions: 3),
    'q3-review': _entity('q3-review', 'Q3 Review', EntityType.event, mentions: 4),
    'running': _entity('running', 'Running', EntityType.activity, mentions: 2),
    'burnout': _entity('burnout', 'Burnout', EntityType.emotion, mentions: 2),
    'ai': _entity('ai', 'AI', EntityType.concept, mentions: 3),
    'sam': _entity('sam', 'Sam', EntityType.person, mentions: 2),
  },
  relations: {for (final relation in _previewRelations) relation.id: relation},
  followUps: const [],
);
