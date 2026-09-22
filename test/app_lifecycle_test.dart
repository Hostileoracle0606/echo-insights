// LumenApp forwards app lifecycle changes to an existing journal: detached
// (swiped away) ends the session; backgrounding does not; and a lifecycle
// change never constructs a journal that does not exist yet.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/app.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/auth_provider.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/auth/login_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

class _CountingJournal extends JournalNotifier {
  int endSessionCalls = 0;
  final seen = <AppLifecycleState>[];

  @override
  JournalState build() => JournalState.empty();

  @override
  void handleAppLifecycle(AppLifecycleState lifecycle) {
    seen.add(lifecycle);
    super.handleAppLifecycle(lifecycle);
  }

  @override
  Future<NotebookTransitionResult> endSession() async {
    endSessionCalls++;
    return const NotebookTransitionResult.success();
  }
}

Future<ProviderContainer> _pumpApp(WidgetTester tester) async {
  final journal = _CountingJournal();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => Stream<User?>.value(null)),
        journalProvider.overrideWith(() => journal),
      ],
      child: const LumenApp(),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(LoginScreen)));
}

void _background(WidgetTester tester) {
  for (final s in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void main() {
  testWidgets('swiping the app away ends the journal session', (tester) async {
    final container = await _pumpApp(tester);
    final journal =
        container.read(journalProvider.notifier) as _CountingJournal;

    _background(tester);
    expect(journal.endSessionCalls, 0, reason: 'background keeps recording');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    expect(journal.seen, contains(AppLifecycleState.detached));
    expect(journal.endSessionCalls, 1);
  });

  testWidgets('returning to the foreground reconciles without ending',
      (tester) async {
    final container = await _pumpApp(tester);
    final journal =
        container.read(journalProvider.notifier) as _CountingJournal;

    _background(tester);
    for (final s in const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    expect(journal.seen, contains(AppLifecycleState.resumed));
    expect(journal.endSessionCalls, 0);
  });

  testWidgets('a lifecycle change never builds a journal', (tester) async {
    final container = await _pumpApp(tester);
    expect(container.exists(journalProvider), isFalse);

    _background(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);

    expect(container.exists(journalProvider), isFalse);
  });
}
