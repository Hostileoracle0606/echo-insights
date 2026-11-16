// LM-103: the catch-up provider follows the runner (running, which cards are
// pending), waits for the app lock, and hands the report to its hook.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/catch_up_provider.dart';
import 'package:lumen/services/catch_up_service.dart';
import 'package:lumen/services/headless_turn_finisher.dart';
import 'package:lumen/services/unfinished_work_service.dart';

void main() {
  late Completer<void> cardGate;
  late List<CatchUpReport> reports;
  late int runners;
  late ProviderContainer container;
  late MemoryCatchUpSkipStore skips;

  setUp(() {
    cardGate = Completer<void>();
    reports = [];
    runners = 0;
    skips = MemoryCatchUpSkipStore();
    container = ProviderContainer(overrides: [
      catchUpSkipStoreProvider.overrideWithValue(skips),
      catchUpRunnerFactoryProvider.overrideWithValue(
        ({required turnsStillRunning, required onPendingCards}) {
          runners++;
          return CatchUpRunner(
            loadWork: () async => const UnfinishedWork(cards: [
              UnfinishedCard(notebookId: 'nb1', revision: 2),
            ]),
            journalNotebookIds: () async => const [],
            newTurnFinisher: () =>
                (id) async => NotebookFinishResult(notebookId: id),
            closeCard: (id) async {
              await cardGate.future;
              return 2;
            },
            requestBrief: (_) async {},
            runErase: (_) async => true,
            skips: skips,
            turnsStillRunning: turnsStillRunning,
            onPendingCards: onPendingCards,
            // No real timers in tests.
            delay: (_) => Completer<void>().future,
          );
        },
      ),
      catchUpFinishedHookProvider.overrideWithValue(reports.add),
    ]);
    addTearDown(container.dispose);
  });

  test('starts idle', () {
    expect(container.read(catchUpProvider), CatchUpState.idle);
    expect(container.read(catchUpProvider).running, isFalse);
  });

  test('nothing runs until the app lock is open', () async {
    final notifier = container.read(catchUpProvider.notifier);
    notifier.request();
    await pumpEventQueue();
    expect(runners, 0);
    expect(container.read(catchUpProvider).running, isFalse);

    notifier.setUnlocked(true);
    await pumpEventQueue();
    expect(runners, 1);
    final state = container.read(catchUpProvider);
    expect(state.running, isTrue);
    expect(state.pendingCardNotebookIds, {'nb1'});
    expect(state.isCardPending('nb1'), isTrue);

    cardGate.complete();
    await notifier.currentRun;
    await pumpEventQueue();
    expect(container.read(catchUpProvider), CatchUpState.idle);
    expect(reports.single.cardsWritten, 1);
  });

  test('sign-out cancels the run and clears the state', () async {
    await skips.write({'card:old': 3});
    final notifier = container.read(catchUpProvider.notifier)
      ..setUnlocked(true)
      ..request();
    await pumpEventQueue();
    expect(container.read(catchUpProvider).running, isTrue);

    notifier.signedOut();
    await pumpEventQueue();
    expect(container.read(catchUpProvider), CatchUpState.idle);
    expect(reports.single.cancelled, isTrue);
    expect(await skips.read(), isEmpty,
        reason: 'the refused-card memory leaves with the account');
  });
}
