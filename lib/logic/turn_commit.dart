import '../models/graph_patch.dart';
import '../models/journal_state.dart';
import '../services/turn_journal_service.dart';
import 'merge.dart' as merge_logic;
import 'turn_state.dart';

/// The extraction result a turn checkpointed, or null when it has none yet.
GraphPatch? checkpointedPatch(FinalizedTurn turn) {
  final stored = turn.extraction;
  return stored == null ? null : GraphPatch.fromJson(stored);
}

/// Merges [patch] for [turn] onto [state] and builds the exact commit
/// envelope to send against [expectedRevision].
///
/// Shared by the open notebook (`JournalNotifier._runCommit`) and the
/// headless finisher, so both prepare a turn by the same merge rules. The
/// envelope must be persisted before it is sent: an unknown outcome is
/// retried with this exact change under the turn's `commitRequestId`.
({PreparedTurnCommit prepared, JournalState next}) prepareTurnCommit({
  required JournalState state,
  required FinalizedTurn turn,
  required GraphPatch patch,
  required int expectedRevision,
  Set<String> suppressed = const {},
}) {
  final result =
      merge_logic.merge(state, turn.transcript, patch, suppressed: suppressed);
  return (
    prepared: PreparedTurnCommit(
      expectedRevision: expectedRevision,
      change: result.change,
      entryId: result.entryId,
    ),
    next: result.next,
  );
}
