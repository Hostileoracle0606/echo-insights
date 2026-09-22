// Dashboard regression: notebooks bucket into Today / This week / Earlier by
// their start date, the hero totals sum correctly, and each card shows its
// title, summary, and meta (with a "live now" badge for an open session).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/notebook.dart';
import 'package:lumen/providers/notebooks_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/dashboard/dashboard_screen.dart';
import 'package:lumen/services/supabase_service.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// A fake whose createNotebook() only resolves when the test tells it to
// (via [resolve]), so the test can hold the button in its "creating" state
// for as long as it needs and count exactly how many times it was invoked.
// The underlying SupabaseClient is never touched (createNotebook is fully
// overridden) — a bare instance just satisfies the constructor.
class _StallingSupabaseService extends SupabaseService {
  _StallingSupabaseService()
      : super(
          SupabaseClient(
            'https://example.supabase.co',
            'anon-key',
            // Disable the client's background token-refresh timer — it would
            // otherwise outlive the test and trip Flutter's pending-timer
            // check on teardown.
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          ),
        );

  int callCount = 0;
  final _completer = Completer<Notebook?>();

  @override
  Future<Notebook?> createNotebook() {
    callCount++;
    return _completer.future;
  }

  void resolve(Notebook? notebook) {
    if (!_completer.isCompleted) _completer.complete(notebook);
  }
}

Notebook _nb(
  String id,
  String title,
  Duration ago,
  int entities, {
  bool live = false,
}) {
  final started = DateTime.now().subtract(ago);
  return Notebook(
    id: id,
    userId: 'demo',
    title: title,
    titleSource: 'ai',
    startedAt: started,
    endedAt: live ? null : started.add(const Duration(minutes: 20)),
    entityCount: entities,
    summary: null,
    createdAt: started,
    updatedAt: started,
  );
}

void main() {
  testWidgets('groups notebooks by time and renders hero totals + cards',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final notebooks = [
      _nb('1', 'Atlas launch', const Duration(minutes: 5), 8, live: true),
      _nb('2', 'Lisbon trip', const Duration(days: 2), 11),
      _nb('3', 'Old brain-dump', const Duration(days: 40), 16),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notebooksProvider.overrideWith((ref) => notebooks),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: const DashboardScreen(),
        ),
      ),
    );
    // Drive the hero's one-shot intro (~1.3s); its amber pulse repeats forever,
    // so don't pumpAndSettle.
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Lumen. logotype (word + period are separate Texts) + the greeting stacked
    // one word per line (assert the first word) + summed totals + dock.
    expect(find.text('Lumen'), findsOneWidget);
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('3 sessions · 35 entities'), findsOneWidget);
    expect(find.text('New notebook'), findsOneWidget);

    // One bucket per spread.
    expect(find.text('TODAY'), findsOneWidget);
    expect(find.text('THIS WEEK'), findsOneWidget);
    expect(find.text('EARLIER'), findsOneWidget);

    // Cards + the live badge on the open session.
    expect(find.text('Atlas launch'), findsOneWidget);
    expect(find.text('Lisbon trip'), findsOneWidget);
    expect(find.textContaining('live now'), findsOneWidget);

    // Unmount so the pulse ticker disposes before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows the empty state when there are no notebooks',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notebooksProvider.overrideWith((ref) => <Notebook>[]),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: const DashboardScreen(),
        ),
      ),
    );
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Greeting stacked one word per line → assert the first word.
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('New notebook'), findsOneWidget);
    expect(find.text('TODAY'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'New notebook button shows a spinner while creating and ignores '
      'a second tap', (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final fakeService = _StallingSupabaseService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notebooksProvider.overrideWith((ref) => <Notebook>[]),
          supabaseServiceProvider.overrideWithValue(fakeService),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: const DashboardScreen(),
        ),
      ),
    );
    for (var i = 0; i < 90; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Idle: icon + label, no spinner.
    expect(find.text('New notebook'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Tap once: createNotebook fires and stalls (the completer isn't
    // resolved yet), so the button should flip into its creating state.
    await tester.tap(find.byKey(const Key('newNotebookButton')));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('New notebook'), findsNothing);
    expect(fakeService.callCount, 1);

    // Tap again while still creating: onTap is disabled, so this must not
    // fire a second createNotebook call.
    await tester.tap(find.byKey(const Key('newNotebookButton')));
    await tester.pump();
    expect(fakeService.callCount, 1);

    // Resolve with null (simulating no signed-in user / RLS failure): the
    // button should recover to idle and surface a snackbar instead of
    // silently doing nothing.
    fakeService.resolve(null);
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('New notebook'), findsOneWidget);
    expect(
      find.textContaining("Couldn't create a notebook"),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a load failure keeps Account reachable and Retry refetches',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var loads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notebooksProvider.overrideWith((ref) async {
            loads++;
            throw StateError('offline');
          }),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: LumenTheme.light(),
          home: const DashboardScreen(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text("Couldn't load your notebooks"), findsOneWidget);
    expect(find.byTooltip('Account'), findsOneWidget);
    expect(loads, 1);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(loads, 2);

    await tester.pumpWidget(const SizedBox());
  });
}
