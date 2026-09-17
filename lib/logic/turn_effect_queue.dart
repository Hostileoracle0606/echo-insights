import 'dart:async';

/// Result of waiting for all durable turn effects to reach a fixed point.
enum TurnEffectDrainStatus { completed, timedOut, failed }

class TurnEffectDrainOutcome {
  const TurnEffectDrainOutcome._(
    this.status, {
    this.error,
    this.stackTrace,
  });

  const TurnEffectDrainOutcome.completed()
      : this._(TurnEffectDrainStatus.completed);

  const TurnEffectDrainOutcome.timedOut()
      : this._(TurnEffectDrainStatus.timedOut);

  const TurnEffectDrainOutcome.failed(Object error, StackTrace stackTrace)
      : this._(
          TurnEffectDrainStatus.failed,
          error: error,
          stackTrace: stackTrace,
        );

  final TurnEffectDrainStatus status;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isCompleted => status == TurnEffectDrainStatus.completed;
}

typedef TurnEffectFailureHandler = void Function(
  Object error,
  StackTrace stackTrace,
);

/// Serializes durable turn effects and exposes a fixed-point drain.
///
/// An effect may enqueue its successor while it is running (for example,
/// extraction dispatches a success event which schedules a commit). A drain
/// therefore cannot await one captured future and call the queue empty: it
/// must keep observing the tail until no newer generation was appended and
/// the turn machine reports no pending durable work.
class TurnEffectQueue {
  TurnEffectQueue({TurnEffectFailureHandler? onFailure})
      : _onFailure = onFailure;

  final TurnEffectFailureHandler? _onFailure;

  Future<void> _tail = Future<void>.value();
  int _generation = 0;
  Object? _failure;
  StackTrace? _failureStackTrace;

  void enqueue(FutureOr<void> Function() operation) {
    _generation += 1;
    final result = _tail.then<void>((_) => Future<void>.sync(operation));
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _failure ??= error;
        _failureStackTrace ??= stackTrace;
        _onFailure?.call(error, stackTrace);
      },
    );
  }

  Future<TurnEffectDrainOutcome> drain({
    required bool Function() hasPendingWork,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final stopwatch = Stopwatch()..start();

    while (true) {
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        return const TurnEffectDrainOutcome.timedOut();
      }

      final observedGeneration = _generation;
      final observedTail = _tail;
      try {
        await observedTail.timeout(remaining);
      } on TimeoutException {
        return const TurnEffectDrainOutcome.timedOut();
      }

      final failure = _failure;
      if (failure != null) {
        return TurnEffectDrainOutcome.failed(
          failure,
          _failureStackTrace ?? StackTrace.current,
        );
      }

      if (_generation != observedGeneration) {
        // Let timers (including the drain timeout) run even if effects keep
        // scheduling immediately-completed successors.
        await Future<void>.delayed(Duration.zero);
        continue;
      }

      if (hasPendingWork()) {
        return TurnEffectDrainOutcome.failed(
          StateError('Turn effect queue stalled with pending durable work'),
          StackTrace.current,
        );
      }

      return const TurnEffectDrainOutcome.completed();
    }
  }
}
