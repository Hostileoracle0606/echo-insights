import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/catch_up_service.dart';
import '../services/headless_turn_finisher.dart';
import '../services/unfinished_work_service.dart';
import 'forget_redactor_provider.dart';
import 'journal_provider.dart';
import 'notebooks_provider.dart';
import 'opening_prep_provider.dart';
import 'supabase_provider.dart';
import 'transcript_erase_provider.dart';

/// Launch-time catch-up as the UI sees it (LM-103): whether a run is going
/// and which notebooks are still waiting for their card. Ids only.
@immutable
class CatchUpState {
  const CatchUpState({
    this.running = false,
    this.pendingCardNotebookIds = const {},
  });

  static const idle = CatchUpState();

  final bool running;
  final Set<String> pendingCardNotebookIds;

  bool isCardPending(String notebookId) =>
      running && pendingCardNotebookIds.contains(notebookId);

  CatchUpState copyWith({bool? running, Set<String>? pendingCardNotebookIds}) =>
      CatchUpState(
        running: running ?? this.running,
        pendingCardNotebookIds:
            pendingCardNotebookIds ?? this.pendingCardNotebookIds,
      );

  @override
  bool operator ==(Object other) =>
      other is CatchUpState &&
      other.running == running &&
      setEquals(other.pendingCardNotebookIds, pendingCardNotebookIds);

  @override
  int get hashCode =>
      Object.hash(running, Object.hashAllUnordered(pendingCardNotebookIds));

  @override
  String toString() =>
      'CatchUpState(running: $running, pending: $pendingCardNotebookIds)';
}

/// Builds one runner per catch-up run. [turnsStillRunning] is shared across
/// runs; [onPendingCards] feeds [CatchUpState.pendingCardNotebookIds].
typedef CatchUpRunnerFactory = CatchUpRunner Function({
  required Set<String> turnsStillRunning,
  required void Function(Set<String> notebookIds) onPendingCards,
});

final unfinishedWorkServiceProvider = Provider<UnfinishedWorkService>(
  (ref) => UnfinishedWorkService(ref.watch(supabaseClientProvider)),
);

/// Card and brief steps the runtime refused for good, by revision.
final catchUpSkipStoreProvider =
    Provider<CatchUpSkipStore>((ref) => FileCatchUpSkipStore());

/// The real runner. Everything is read when a run starts, never when the
/// provider is built, so building it touches no service.
final catchUpRunnerFactoryProvider = Provider<CatchUpRunnerFactory>((ref) {
  return ({required turnsStillRunning, required onPendingCards}) {
    final journal = ref.read(turnJournalServiceProvider);
    final commit = ref.read(notebookCommitServiceProvider);
    final session = ref.read(journalProvider.notifier);
    return CatchUpRunner(
      // Owner-scoped on the server (auth.uid()): only this account's work.
      loadWork: () => ref.read(unfinishedWorkServiceProvider).load(),
      // The journal is per phone; a notebook of another account answers
      // notFound and its turns stay journalled (HeadlessTurnFinisher).
      journalNotebookIds: journal.listNotebookIdsWithTurns,
      // A new finisher per run: its notFound skip set lives on the instance.
      newTurnFinisher: () => HeadlessTurnFinisher(
        journal: journal,
        commit: commit.commitNotebook,
        loadSnapshot: commit.getNotebookSnapshot,
        extract: (r) => ref.read(extractGraphServiceProvider).extract(
              notebookId: r.notebookId,
              turnId: r.turnId,
              // The notifier's: the runtime caches by it.
              extractorVersion: extractorVersion,
              text: r.text,
              state: r.state,
              mode: 'granular',
              recentConversation: r.recentConversation,
            ),
        redaction: TurnRedaction.of(ref.read(forgetRedactorProvider)),
      ).finishNotebook,
      // close() asks get_card_status first; null is a 422/501 answer.
      closeCard: (notebookId) async =>
          (await ref.read(sessionCardServiceProvider).close(notebookId))
              ?.sourceRevision,
      requestBrief: (notebookId) =>
          ref.read(sessionBriefServiceProvider).requestBrief(notebookId),
      // The erase notifier's own run: numbered batches, shared with the
      // resume at launch (one run per job).
      runErase: (jobId) => ref.read(transcriptEraseProvider.notifier).run(jobId),
      // No embed call from the phone yet: the server's embed-reconcile sweep
      // builds missing vectors, and search works without them meanwhile.
      buildVectors: null,
      skips: ref.read(catchUpSkipStoreProvider),
      // The open notebook's turns are the notifier's, except after a failed
      // leave (status error): then the user has left and catch-up may.
      //
      // Known window: a session can open a notebook while its turn step is
      // already running here. Both then work on the same journalled turns.
      // That is safe, only wasteful: extraction is cached by turn id, and a
      // commit goes through the request ledger (the same envelope is
      // answered once; a different one under the same id is refused as
      // requestIdReused, which drops the already-committed turn). The step is
      // bounded by the step timeout, and a later run skips the notebook while
      // the step is still going (turnsStillRunning).
      openNotebookId: () => session.catchUpOpenNotebookId,
      isNotebookLive: session.isNotebookLive,
      turnsStillRunning: turnsStillRunning,
      onPendingCards: onPendingCards,
    );
  };
});

/// What follows a run: the dashboard reads the new cards, the opening the
/// new brief.
final catchUpFinishedHookProvider =
    Provider<void Function(CatchUpReport report)>((ref) {
  return (report) {
    if (report.cardsWritten > 0) ref.invalidate(notebooksProvider);
    if (report.briefsWritten > 0) {
      unawaited(ref.read(openingPrepProvider).refresh());
    }
  };
});

final catchUpProvider =
    NotifierProvider<CatchUpNotifier, CatchUpState>(CatchUpNotifier.new);

/// Starts catch-up on launch and resume (after sign-in, once the app lock is
/// open), one run at a time, in the background. See [CatchUpScheduler].
class CatchUpNotifier extends Notifier<CatchUpState> {
  final _turnsStillRunning = <String>{};
  bool _disposed = false;

  late final CatchUpScheduler _scheduler = CatchUpScheduler(
    run: (token) => ref
        .read(catchUpRunnerFactoryProvider)(
          turnsStillRunning: _turnsStillRunning,
          onPendingCards: (ids) =>
              _set(state.copyWith(pendingCardNotebookIds: ids)),
        )
        .run(token),
    onRunning: (running) => _set(running
        ? state.copyWith(running: true)
        : CatchUpState.idle),
    onReport: (report) {
      try {
        ref.read(catchUpFinishedHookProvider)(report);
      } catch (error) {
        debugPrint('catch-up: after-run hook failed (${error.runtimeType})');
      }
    },
  );

  @override
  CatchUpState build() {
    ref.onDispose(() {
      _disposed = true;
      _scheduler.signedOut();
    });
    return CatchUpState.idle;
  }

  void _set(CatchUpState next) {
    if (_disposed) return;
    state = next;
  }

  /// Launch or resume (signed in). Never waits, never throws: a session can
  /// start while it runs.
  void request() => _scheduler.request();

  /// Follows the app lock: runs wait for it to open; locking cancels.
  void setUnlocked(bool unlocked) => _scheduler.setUnlocked(unlocked);

  /// The account left: stop, and forget what was asked.
  void signedOut() {
    _scheduler.signedOut();
    _set(CatchUpState.idle);
    // The refused-card memory belongs to the account that left.
    unawaited(ref.read(catchUpSkipStoreProvider).clear());
  }

  /// The run in flight, if any (tests wait on it).
  Future<void>? get currentRun => _scheduler.current;
}
