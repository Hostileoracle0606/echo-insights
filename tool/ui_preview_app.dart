import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/models/session_card.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/session_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/models/upsert_activity.dart';
import 'package:lumen/screens/auth/login_screen.dart';
import 'package:lumen/screens/auth/signup_screen.dart';
import 'package:lumen/screens/card/closing_card_screen.dart';
import 'package:lumen/screens/journal/graph_canvas.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/screens/journal/journal_top_bar.dart';
import 'package:lumen/screens/journal/voice_dock.dart';
import 'package:lumen/services/memory_control_service.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/session_card_service.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_text.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/context_tile.dart';
import 'package:lumen/widgets/mode_header.dart';
import 'package:lumen/widgets/result_card.dart';

void main() {
  const screen = String.fromEnvironment('SCREEN', defaultValue: 'login');
  runApp(const _PreviewApp(screen: screen));
}

class _PreviewApp extends StatelessWidget {
  final String screen;

  const _PreviewApp({required this.screen});

  @override
  Widget build(BuildContext context) {
    if (screen.startsWith('card-') || screen == 'card') {
      return _ClosingCardPreview(screen: screen);
    }
    final overrides = switch (screen) {
      'journal' => <Override>[
          journalProvider.overrideWith(_PreviewJournalNotifier.new),
          sessionStatusProvider.overrideWithValue(SessionStatus.live),
          liveUserTextProvider.overrideWithValue(
            'Maya said the Atlas demo finally feels real, but I still do not know who owns the handoff.',
          ),
          upsertActivityProvider.overrideWithValue(
            const UpsertActivity(
              id: 1,
              entityNames: ['Maya', 'Project Atlas'],
              insertedEntities: 0,
              updatedEntities: 2,
              createdRelations: 1,
            ),
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
          'cards' => const _CardsPreview(),
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
  JournalView _view = JournalView.graph;

  static const _transcripts = <DockMode, String>{
    DockMode.listening:
        '…had coffee with Maya about the Atlas launch timeline.',
    DockMode.speaking:
        'When did the Atlas launch slip — was that the Q3 review?',
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
          // Full width, so the dock centres on the screen and not on the
          // widest child.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            Text(
              'VoiceDock · ${_mode.name}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'tap the mic to cycle states · tap View to switch views',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            VoiceDock(
              mode: _mode,
              liveUser:
                  _mode == DockMode.speaking ? '' : _transcripts[_mode] ?? '',
              liveAgent:
                  _mode == DockMode.speaking ? _transcripts[_mode] ?? '' : '',
              onMicTap: _cycle,
              view: _view,
              onViewChanged: (view) => setState(() => _view = view),
            ),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

/// LM-09 shared result pieces on one scrolling page, with the prototype's
/// copy: a ModeHeader with a sample timer pill, a ResultCard with and without
/// a hero row, a ContextTile and a ContextList whose × buttons really remove.
class _CardsPreview extends StatefulWidget {
  const _CardsPreview();

  @override
  State<_CardsPreview> createState() => _CardsPreviewState();
}

class _CardsPreviewState extends State<_CardsPreview> {
  var _remember = const [
    ContextItem(title: 'Priya', note: 'paired on the cache keys'),
    ContextItem(title: 'CI build time', note: '22 → 13 min'),
    ContextItem(title: 'Ask Priya about the Q4 rollout', open: true),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ModeHeader(
              title: 'Weekly debrief',
              onBack: () {},
              trailing: const _SamplePill(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
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
                  const SizedBox(height: 16),
                  ContextList(
                    eyebrow: 'Lumen will remember',
                    items: _remember,
                    onRemove: (item) => setState(() {
                      _remember = [..._remember]..remove(item);
                    }),
                  ),
                  const SizedBox(height: 28),
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
                  const SizedBox(height: 16),
                  const ContextTile(
                    icon: Icons.history,
                    eyebrow: 'Since last time',
                    body:
                        'You wanted Priya to get credit for the cache-key fix '
                        'in your review.',
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'preview · cards',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _ciWin =
    'Cut CI build time 41% (22 → 13 min) by fixing cache keys, with Priya.';

/// Stand-in for LM-11's timer pill and End, to exercise ModeHeader's slot.
class _SamplePill extends StatelessWidget {
  const _SamplePill();

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.recallRing,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '12:04',
            style: TextStyle(
              fontFamily: LumenText.sansFontFamily,
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: colors.ink,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: colors.ink,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              'End',
              style: TextStyle(
                fontFamily: LumenText.sansFontFamily,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.paper,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewJournalNotifier extends JournalNotifier {
  @override
  JournalState build() => _previewState;

  // No live session here: accept typed turns so the composer clears.
  @override
  bool sendTypedTurn(String text) => text.trim().isNotEmpty;
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
    'q3-review':
        _entity('q3-review', 'Q3 Review', EntityType.event, mentions: 4),
    'running': _entity('running', 'Running', EntityType.activity, mentions: 2),
    'burnout': _entity('burnout', 'Burnout', EntityType.emotion, mentions: 2),
    'ai': _entity('ai', 'AI', EntityType.concept, mentions: 3),
    'sam': _entity('sam', 'Sam', EntityType.person, mentions: 2),
  },
  relations: {for (final relation in _previewRelations) relation.id: relation},
  followUps: const [],
);

// ─── LM-16: the closing card, from the contract fixtures ────────────────────
//
// SCREEN=card (Just talk), card-debrief or card-failed. The card arrives
// after 1.2 s so the loading state shows; Done, Talk, Type and View land on
// stand-in pages. Copies of contracts/fixtures/session-card-v1.*.json (the
// app bundle can't read the repo's files).

const _justTalkFixture = {
  "version": 1,
  "notebookId": "8e03b8f4-4f20-4df3-8398-d854adc32b14",
  "conversationMode": "just_talk",
  "sourceRevision": 7,
  "generatedAt": "2026-10-23T21:14:05.000Z",
  "title": "Maya's move and a slower week",
  "summary":
      "You talked about helping Maya move to Brooklyn, feeling stretched by the Atlas demo, and wanting your Sunday runs back.",
  "remember": [
    {
      "entityId": "maya",
      "name": "Maya",
      "type": "person",
      "note": "Moving to Brooklyn next month; you're helping her pack.",
      "isNew": false,
    },
    {
      "entityId": "project_atlas",
      "name": "Project Atlas",
      "type": "project",
      "note": "The demo is Thursday and it's taking most of your evenings.",
      "isNew": false,
    },
    {
      "entityId": "running",
      "name": "running",
      "type": "activity",
      "note": "You want your Sunday runs back.",
      "isNew": true,
    },
    {
      "entityId": "brooklyn",
      "name": "Brooklyn",
      "type": "place",
      "note": null,
      "isNew": true,
    },
  ],
  "notes": [
    "Maya is moving to Brooklyn next month, and you said you'd help her pack.",
    "The Atlas demo is on Thursday and has taken most of your evenings this week.",
    "You miss your Sunday runs and want to start them again after the demo.",
  ],
};

const _debriefFixture = {
  "version": 1,
  "notebookId": "0b6f1d6e-3c1a-4a51-9d0e-2f7c9a1b4e21",
  "conversationMode": "weekly_debrief",
  "sourceRevision": 12,
  "generatedAt": "2026-10-23T17:42:10.000Z",
  "title": "CI fix landed",
  "summary":
      "You merged the CI fix on Tuesday, cut build time from 22 to 13 minutes with Priya, and you're still waiting on staging DB access.",
  "remember": [
    {
      "entityId": "priya",
      "name": "Priya",
      "type": "person",
      "note": "Figured out the cache keys for the CI fix.",
      "isNew": false,
    },
    {
      "entityId": "ci_pipeline",
      "name": "CI pipeline",
      "type": "project",
      "note": "Builds went from 22 minutes to 13.",
      "isNew": false,
    },
    {
      "entityId": "staging_db",
      "name": "Staging DB",
      "type": "project",
      "note": "Access still pending; ask next Friday.",
      "isNew": true,
    },
  ],
  "weekOf": "2026-10-19",
  "nextDebriefOn": "2026-10-30",
  "briefTotal": 41,
  "wins": [
    {
      "text":
          "Cut CI build time 41% (22 \u2192 13 min) by fixing cache keys, with Priya.",
      "metric": {
        "before": 22,
        "after": 13,
        "unit": "min",
      },
      "helpers": [
        "Priya",
      ],
      "top": true,
    },
    {
      "text": "Merged the CI fix on Tuesday, a day ahead of plan.",
      "helpers": [],
      "top": false,
    },
    {
      "text": "Walked the new hire through the deploy runbook.",
      "helpers": [],
      "top": false,
    },
  ],
  "openItems": {
    "created": [
      {
        "id": "4d2c7a90-8b1e-4f3a-a6d5-1e9b0c7f2a34",
        "text": "Staging DB access",
        "dueOn": "2026-10-30",
      },
    ],
    "resolvedIds": [
      "c1f8e2b4-6a3d-4e7f-9b0a-5d2c8e1f4a67",
    ],
  },
};

class _PreviewCards implements SessionCardService {
  _PreviewCards(this.screen);
  final String screen;

  @override
  Future<SessionCard?> close(String notebookId, {int maxRetries = 2}) async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    return switch (screen) {
      'card-failed' => throw const SessionCardException('preview'),
      'card-debrief' => SessionCard.fromJson(_debriefFixture),
      _ => SessionCard.fromJson(_justTalkFixture),
    };
  }

  @override
  Future<SessionCard?> load(String notebookId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PreviewCommits implements NotebookCommitService {
  @override
  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async =>
      NotebookSnapshot(
          notebookId: notebookId, revision: 0, state: _previewState);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ClosingCardPreview extends StatelessWidget {
  const _ClosingCardPreview({required this.screen});
  final String screen;

  @override
  Widget build(BuildContext context) {
    Widget standIn(String text) => Scaffold(body: Center(child: Text(text)));
    final router = GoRouter(
      initialLocation: '/notebook/preview/card',
      routes: [
        GoRoute(path: '/dashboard', builder: (_, __) => standIn('Dashboard')),
        GoRoute(
          path: '/notebook/:id',
          builder: (_, state) => standIn('Notebook ${state.uri}'),
          routes: [
            GoRoute(
              path: 'card',
              builder: (_, state) =>
                  ClosingCardScreen(notebookId: state.pathParameters['id']!),
            ),
          ],
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        sessionCardServiceProvider.overrideWithValue(_PreviewCards(screen)),
        notebookCommitServiceProvider.overrideWithValue(_PreviewCommits()),
        memoryControlServiceProvider.overrideWithValue(
          MemoryControlService.withRpc((_, __) async => {'removedFrom': 1}),
        ),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: LumenTheme.light(),
        routerConfig: router,
      ),
    );
  }
}
