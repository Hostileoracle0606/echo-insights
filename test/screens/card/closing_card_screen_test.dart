// LM-16: the closing card screen, rendered from the contract fixtures. It
// fetches everything by notebook id (the notebook was already left): the card
// from SessionCardService, the revision, suppressions and export state from
// the notebook snapshot, and removals go to MemoryControlService.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumen/logic/card_dates.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/session_card.dart';
import 'package:lumen/providers/export_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/card/closing_card_screen.dart';
import 'package:lumen/services/markdown_export.dart';
import 'package:lumen/services/memory_control_service.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/session_card_service.dart';
import 'package:lumen/theme/lumen_colors.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:lumen/widgets/result_card.dart';

Map<String, dynamic> _fixture(String mode) => jsonDecode(
      File('contracts/fixtures/session-card-v1.$mode.json').readAsStringSync(),
    ) as Map<String, dynamic>;

final _justTalk = SessionCard.fromJson(_fixture('just_talk'));
final _debrief = SessionCard.fromJson(_fixture('weekly_debrief'));
final _prep = SessionCard.fromJson(_fixture('session_prep'));

class _FakeCards implements SessionCardService {
  _FakeCards({this.onClose, this.stored});

  /// Each close() call runs this; defaults to a pending future.
  Future<SessionCard?> Function()? onClose;
  SessionCard? stored;
  final closeCompleter = Completer<SessionCard?>();
  int closeCalls = 0;

  @override
  Future<SessionCard?> close(String notebookId, {int maxRetries = 2}) {
    closeCalls += 1;
    return onClose?.call() ?? closeCompleter.future;
  }

  @override
  Future<SessionCard?> load(String notebookId) async => stored;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCommits implements NotebookCommitService {
  _FakeCommits({this.revision = 7, this.suppressed = const {}});

  int revision;
  Set<String> suppressed;
  Object? failWith;
  int snapshots = 0;

  @override
  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async {
    snapshots += 1;
    if (failWith != null) throw failWith!;
    return NotebookSnapshot(
      notebookId: notebookId,
      revision: revision,
      suppressedEntityIds: suppressed,
      state: _exportState(),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMemory implements MemoryControlService {
  final removed = <String>[];

  @override
  Future<int> removeEntity(String entityId) async {
    removed.add(entityId);
    return 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

JournalState _exportState() {
  final at = DateTime.utc(2026, 10, 23, 21);
  Entity entity(String id, String name, EntityType type) => Entity(
        id: id,
        name: name,
        type: type,
        metadata: const {},
        mentions: 1,
        firstSeen: at,
        lastSeen: at,
      );
  return JournalState.empty().copyWith(entities: {
    'maya': entity('maya', 'Maya', EntityType.person),
    'running': entity('running', 'running', EntityType.activity),
  });
}

class _Harness {
  _Harness({
    required this.cards,
    required this.commits,
    required this.memory,
    required this.router,
    required this.shared,
  });

  final _FakeCards cards;
  final _FakeCommits commits;
  final _FakeMemory memory;
  final GoRouter router;
  final List<MarkdownVault> shared;

  String get location =>
      router.routerDelegate.currentConfiguration.uri.toString();
}

const _id = 'nb-1';

Future<_Harness> _pump(
  WidgetTester tester, {
  _FakeCards? cards,
  _FakeCommits? commits,
  Future<void> Function(MarkdownVault vault)? share,
}) async {
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final fakeCards = cards ?? _FakeCards(onClose: () async => _justTalk);
  final fakeCommits = commits ?? _FakeCommits();
  final memory = _FakeMemory();
  final shared = <MarkdownVault>[];
  final router = GoRouter(
    initialLocation: '/notebook/$_id/card',
    routes: [
      GoRoute(
        path: '/dashboard',
        builder: (_, __) => const Scaffold(body: Text('Dashboard ready')),
      ),
      GoRoute(
        path: '/notebook/:id',
        builder: (_, state) => Scaffold(body: Text('Notebook ${state.uri}')),
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
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionCardServiceProvider.overrideWithValue(fakeCards),
        notebookCommitServiceProvider.overrideWithValue(fakeCommits),
        memoryControlServiceProvider.overrideWithValue(memory),
        shareVaultProvider.overrideWithValue(
          (vault, {Rect? origin}) async {
            shared.add(vault);
            await share?.call(vault);
          },
        ),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: LumenTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  await _frames(tester);
  return _Harness(
    cards: fakeCards,
    commits: fakeCommits,
    memory: memory,
    router: router,
    shared: shared,
  );
}

// The pill's pulse clock repeats forever, so step frames rather than
// pumpAndSettle.
Future<void> _frames(WidgetTester tester, {int count = 20}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _unmount(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _frames(tester, count: 3);
  await tester.tap(finder);
  await _frames(tester);
}

void main() {
  group('states', () {
    testWidgets('loading shows calm progress copy while the card is written',
        (tester) async {
      final h = await _pump(tester, cards: _FakeCards());
      expect(find.text('Writing your card…'), findsOneWidget);
      expect(h.cards.closeCalls, 1);
      await _unmount(tester);
    });

    testWidgets('a stored card that is current shows before close returns',
        (tester) async {
      final h = await _pump(
        tester,
        cards: _FakeCards(stored: _justTalk),
        commits: _FakeCommits(revision: _justTalk.sourceRevision),
      );
      expect(find.text('Writing your card…'), findsNothing);
      expect(find.textContaining(_justTalk.summary), findsOneWidget);
      expect(h.cards.closeCalls, 1, reason: 'close still runs');
      await _unmount(tester);
    });

    testWidgets('a stored card from an older revision waits for close',
        (tester) async {
      final h = await _pump(
        tester,
        cards: _FakeCards(stored: _justTalk),
        commits: _FakeCommits(revision: _justTalk.sourceRevision + 1),
      );
      expect(find.text('Writing your card…'), findsOneWidget);

      h.cards.closeCompleter.complete(_justTalk);
      await _frames(tester);
      expect(find.textContaining(_justTalk.summary), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('no card (a mode without one yet) says it was saved',
        (tester) async {
      await _pump(tester, cards: _FakeCards(onClose: () async => null));
      expect(find.text('Your conversation is saved.'), findsOneWidget);
      expect(find.bySemanticsLabel('Done'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('a mode whose layout is not built yet shows the saved state',
        (tester) async {
      await _pump(tester, cards: _FakeCards(onClose: () async => _prep));
      expect(find.text('Your conversation is saved.'), findsOneWidget);
      expect(find.text('WHAT YOU TALKED ABOUT'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('failed says so, and Try again makes one more call',
        (tester) async {
      var calls = 0;
      final cards = _FakeCards(onClose: () async {
        calls += 1;
        if (calls == 1) {
          throw const SessionCardException('down', statusCode: 503);
        }
        return _justTalk;
      });
      final h = await _pump(tester, cards: cards);

      expect(
        find.text("Couldn't write your card. Your conversation is saved."),
        findsOneWidget,
      );
      // One call, no retry loop.
      await _frames(tester, count: 60);
      expect(h.cards.closeCalls, 1);

      await tester.tap(find.bySemanticsLabel('Try again'));
      await _frames(tester);
      expect(h.cards.closeCalls, 2);
      expect(find.textContaining(_justTalk.summary), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('Just talk', () {
    testWidgets('renders the day, title, summary, notes and remember list',
        (tester) async {
      await _pump(tester);

      expect(find.text('Just talk'), findsOneWidget);
      expect(
        find.text(shortDay(_justTalk.generatedAt.toLocal()).toUpperCase()),
        findsOneWidget,
      );
      // The title ends on an amber period.
      final title = tester.widget<RichText>(find.byWidgetPredicate((widget) =>
          widget is RichText &&
          widget.text.toPlainText() == '${_justTalk.title}.'));
      final spans = <InlineSpan>[];
      title.text.visitChildren((span) {
        spans.add(span);
        return true;
      });
      final period = spans.whereType<TextSpan>().last;
      expect(period.text, '.');
      expect(period.style!.color, LumenColors.light.amber);
      expect(find.text(_justTalk.summary), findsOneWidget);

      expect(find.text('WHAT YOU TALKED ABOUT'), findsOneWidget);
      final hero = find.byKey(ResultCard.heroKey);
      expect(
        find.descendant(of: hero, matching: find.text(_justTalk.notes.first)),
        findsOneWidget,
      );
      for (final note in _justTalk.notes.skip(1)) {
        expect(find.text(note), findsOneWidget);
        expect(
            find.descendant(of: hero, matching: find.text(note)), findsNothing);
      }

      expect(find.text('LUMEN WILL REMEMBER'), findsOneWidget);
      expect(
        find.textContaining(
            "Moving to Brooklyn next month; you're helping her pack."),
        findsOneWidget,
      );
      expect(find.textContaining('You want your Sunday runs back. · new'),
          findsOneWidget);
      // Brooklyn has no note, only "new".
      final brooklyn = find.byWidgetPredicate((widget) =>
          widget is RichText && widget.text.toPlainText() == 'Brooklyn  new');
      expect(brooklyn, findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('remember dots use the entity colours', (tester) async {
      await _pump(tester);
      final dots = tester
          .widgetList<Container>(
              find.byKey(const ValueKey('context-dot-filled')))
          .map((c) => (c.decoration! as BoxDecoration).color)
          .toList();
      expect(dots, [
        LumenColors.entityColors[EntityType.person],
        LumenColors.entityColors[EntityType.project],
        LumenColors.entityColors[EntityType.activity],
        LumenColors.entityColors[EntityType.place],
      ]);
      await _unmount(tester);
    });

    testWidgets('items already removed from memory are hidden on load',
        (tester) async {
      await _pump(tester, commits: _FakeCommits(suppressed: {'maya'}));
      expect(find.bySemanticsLabel('Remove Maya'), findsNothing);
      expect(find.bySemanticsLabel('Remove Project Atlas'), findsOneWidget);
      await _unmount(tester);
    });

    testWidgets('Done and back go to the dashboard', (tester) async {
      var h = await _pump(tester);
      await tester.tap(find.bySemanticsLabel('Done'));
      await _frames(tester);
      expect(h.location, '/dashboard');
      await _unmount(tester);

      h = await _pump(tester);
      await tester.tap(find.bySemanticsLabel('Back, Just talk'));
      await _frames(tester);
      expect(h.location, '/dashboard');
      await _unmount(tester);
    });
  });

  group('removing what Lumen remembers', () {
    Future<void> confirmRemoveMaya(WidgetTester tester) async {
      await _tapVisible(tester, find.bySemanticsLabel('Remove Maya'));
      expect(find.text('Remove Maya?'), findsOneWidget);
      expect(
        find.textContaining("Lumen will forget Maya and won't add them back."),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await _frames(tester);
    }

    testWidgets('cancel keeps the item', (tester) async {
      final h = await _pump(tester);
      await _tapVisible(tester, find.bySemanticsLabel('Remove Maya'));
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(find.bySemanticsLabel('Remove Maya'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(h.memory.removed, isEmpty);
      await _unmount(tester);
    });

    testWidgets('confirm hides it; Undo brings it back and sends nothing',
        (tester) async {
      final h = await _pump(tester);
      await confirmRemoveMaya(tester);

      expect(find.bySemanticsLabel('Remove Maya'), findsNothing);
      expect(find.text('Removed Maya'), findsOneWidget);
      expect(h.memory.removed, isEmpty, reason: 'still inside the window');

      await tester.tap(find.text('Undo'));
      await _frames(tester);
      expect(find.bySemanticsLabel('Remove Maya'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      expect(h.memory.removed, isEmpty);
      await _unmount(tester);
    });

    testWidgets('without Undo it is removed exactly once after 5 s',
        (tester) async {
      final h = await _pump(tester);
      await confirmRemoveMaya(tester);

      await tester.pump(const Duration(milliseconds: 4500));
      expect(h.memory.removed, isEmpty);
      await tester.pump(const Duration(milliseconds: 600));
      expect(h.memory.removed, ['maya']);

      await tester.pump(const Duration(seconds: 10));
      expect(h.memory.removed, ['maya']);
      expect(find.bySemanticsLabel('Remove Maya'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('going to the background removes it at once', (tester) async {
      final h = await _pump(tester);
      await confirmRemoveMaya(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(h.memory.removed, ['maya']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _unmount(tester);
    });

    testWidgets('leaving the card inside the window still removes it',
        (tester) async {
      final h = await _pump(tester);
      await confirmRemoveMaya(tester);
      await tester.tap(find.bySemanticsLabel('Done'));
      await _frames(tester, count: 40);
      expect(h.location, '/dashboard');
      expect(h.memory.removed, ['maya']);
      await _frames(tester, count: 30); // the bar's exit animation
      expect(find.text('Removed Maya'), findsNothing,
          reason: 'no Undo left on a screen that can no longer undo');
      await _unmount(tester);
    });
  });

  group('export', () {
    testWidgets('builds the vault from the snapshot and shares it',
        (tester) async {
      final h = await _pump(tester);
      final before = h.commits.snapshots;

      await _tapVisible(tester, find.bySemanticsLabel('Export as Markdown'));

      expect(h.commits.snapshots, before + 1, reason: 'a fresh snapshot');
      expect(h.shared, hasLength(1));
      expect(h.shared.single.files.keys, contains('Lumen Vault/Maya.md'));
      await _unmount(tester);
    });

    testWidgets('an item inside its undo window is left out of the export',
        (tester) async {
      final h = await _pump(tester);
      await _tapVisible(tester, find.bySemanticsLabel('Remove Maya'));
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await _frames(tester);

      await _tapVisible(tester, find.bySemanticsLabel('Export as Markdown'));
      expect(
          h.shared.single.files.keys, isNot(contains('Lumen Vault/Maya.md')));
      await _unmount(tester);
    });

    testWidgets('shows busy while it runs and an error if it fails',
        (tester) async {
      final release = Completer<void>();
      final h = await _pump(tester, share: (_) => release.future);

      await _tapVisible(tester, find.bySemanticsLabel('Export as Markdown'));
      expect(find.text('Building export…'), findsOneWidget);
      release.complete();
      await _frames(tester);
      expect(find.text('Export as Markdown'), findsOneWidget);

      h.commits.failWith = Exception('offline');
      await _tapVisible(tester, find.bySemanticsLabel('Export as Markdown'));
      expect(
          find.text("Couldn't build the export. Try again."), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('keep going', () {
    testWidgets('Talk, Type and View open the notebook', (tester) async {
      var h = await _pump(tester);
      await tester.tap(find.bySemanticsLabel('Microphone'));
      await _frames(tester);
      expect(h.location, '/notebook/$_id?start=true');
      await _unmount(tester);

      h = await _pump(tester);
      await tester.tap(find.bySemanticsLabel('Type instead'));
      await _frames(tester);
      expect(h.location, '/notebook/$_id?compose=true');
      await _unmount(tester);

      h = await _pump(tester);
      await tester.tap(find.bySemanticsLabel('Show transcript'));
      await _frames(tester);
      expect(h.location, '/notebook/$_id');
      await _unmount(tester);
    });
  });

  group('weekly debrief', () {
    testWidgets('renders the week, wins, brief total and open items',
        (tester) async {
      await _pump(tester, cards: _FakeCards(onClose: () async => _debrief));

      expect(find.text('Weekly debrief'), findsOneWidget);
      final day = shortDay(_debrief.generatedAt.toLocal());
      expect(find.text('$day · Next one Oct 30'.toUpperCase()), findsOneWidget);
      expect(
        find.byWidgetPredicate((widget) =>
            widget is RichText &&
            widget.text.toPlainText() == 'Added to your review brief.'),
        findsOneWidget,
      );

      expect(find.text('THIS WEEK · 3 WINS'), findsOneWidget);
      final hero = find.byKey(ResultCard.heroKey);
      expect(find.descendant(of: hero, matching: find.text('TOP WIN')),
          findsOneWidget);
      expect(
        find.descendant(
          of: hero,
          matching: find
              .text('Cut CI build time 41% (22 → 13 min) by fixing cache keys, '
                  'with Priya.'),
        ),
        findsOneWidget,
      );
      expect(find.text('Merged the CI fix on Tuesday, a day ahead of plan.'),
          findsOneWidget);
      expect(find.text('41 wins in your brief'), findsOneWidget);

      // Remember items plus the open item, hollow and not removable.
      expect(find.bySemanticsLabel('Remove Priya'), findsOneWidget);
      expect(find.byKey(const ValueKey('context-dot-open')), findsOneWidget);
      expect(find.textContaining('Staging DB access'), findsWidgets);
      expect(
        find.byWidgetPredicate((widget) =>
            widget is RichText &&
            widget.text.toPlainText() == 'Staging DB access  ask next Friday'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Remove Staging DB access'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('Copy bullets copies the wins as plain-text bullets',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await _pump(tester, cards: _FakeCards(onClose: () async => _debrief));
      await _tapVisible(tester, find.bySemanticsLabel('Copy bullets'));

      expect(
        copied,
        '• Cut CI build time 41% (22 → 13 min) by fixing cache keys, with Priya.\n'
        '• Merged the CI fix on Tuesday, a day ahead of plan.\n'
        '• Walked the new hire through the deploy runbook.',
      );
      expect(find.text('Copied 3 wins'), findsOneWidget);
      await _unmount(tester);
    });
  });

  testWidgets('targets are at least 44 pt and labelled for VoiceOver',
      (tester) async {
    await _pump(tester);
    for (final label in [
      'Done',
      'Back, Just talk',
      'Remove Maya',
      'Export as Markdown',
      'Microphone',
      'Type instead',
    ]) {
      final target = find.bySemanticsLabel(label);
      expect(target, findsOneWidget, reason: label);
      final size = tester.getSize(target);
      expect(size.width, greaterThanOrEqualTo(44), reason: label);
      expect(size.height, greaterThanOrEqualTo(44), reason: label);
    }
    await _unmount(tester);
  });
}
