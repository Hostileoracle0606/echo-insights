import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/turn_effect_queue.dart';

void main() {
  test('drain waits for the current effect', () async {
    final queue = TurnEffectQueue();
    final effect = Completer<void>();
    queue.enqueue(() => effect.future);

    var completed = false;
    final draining = queue
        .drain(hasPendingWork: () => false)
        .then((outcome) => completed = outcome.isCompleted);

    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    effect.complete();
    await draining;
    expect(completed, isTrue);
  });

  test('drain follows effects appended by an in-flight effect', () async {
    final queue = TurnEffectQueue();
    final extraction = Completer<void>();
    final commit = Completer<void>();
    var commitStarted = false;

    queue.enqueue(() async {
      await extraction.future;
      queue.enqueue(() async {
        commitStarted = true;
        await commit.future;
      });
    });

    final draining = queue.drain(hasPendingWork: () => false);
    extraction.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(commitStarted, isTrue);
    var drainCompleted = false;
    draining.then((_) => drainCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(drainCompleted, isFalse);

    commit.complete();
    expect((await draining).status, TurnEffectDrainStatus.completed);
  });

  test('drain times out without cancelling the in-flight effect', () async {
    final queue = TurnEffectQueue();
    final effect = Completer<void>();
    queue.enqueue(() => effect.future);

    final outcome = await queue.drain(
      hasPendingWork: () => true,
      timeout: const Duration(milliseconds: 10),
    );

    expect(outcome.status, TurnEffectDrainStatus.timedOut);
    effect.complete();
    expect(
      (await queue.drain(hasPendingWork: () => false)).status,
      TurnEffectDrainStatus.completed,
    );
  });

  test('drain reports an effect failure', () async {
    final queue = TurnEffectQueue();
    queue.enqueue(() => throw StateError('checkpoint failed'));

    final outcome = await queue.drain(hasPendingWork: () => true);

    expect(outcome.status, TurnEffectDrainStatus.failed);
    expect(outcome.error, isA<StateError>());
  });

  test('drain rejects a stable queue that still has pending work', () async {
    final queue = TurnEffectQueue();

    final outcome = await queue.drain(hasPendingWork: () => true);

    expect(outcome.status, TurnEffectDrainStatus.failed);
    expect('${outcome.error}', contains('stalled'));
  });
}
