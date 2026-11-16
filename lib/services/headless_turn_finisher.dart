import '../logic/conversation_policy.dart' show extractAssistantTurns;
import '../logic/forget_redaction.dart';
import '../logic/turn_commit.dart';
import '../logic/turn_state.dart' show DurableStage, FinalizedTurn, Speaker;
import '../logic/voice_log.dart';
import '../models/graph_patch.dart';
import '../models/journal_state.dart';
import 'notebook_commit_service.dart';
import 'turn_journal_service.dart';

/// `NotebookCommitService.commitNotebook`, as a function.
typedef CommitNotebookFn = Future<CommitOutcome> Function({
  required String notebookId,
  required int expectedRevision,
  required String requestId,
  required NotebookChange change,
});

/// `NotebookCommitService.getNotebookSnapshot`, as a function.
typedef LoadNotebookSnapshotFn = Future<NotebookSnapshot?> Function(
  String notebookId,
);

/// Runs graph extraction for one journalled turn, keyed by its turn id (the
/// extract-graph runtime caches by turn id and refuses a changed input).
typedef ExtractJournalTurnFn = Future<GraphPatch> Function(
  HeadlessExtraction request,
);

/// What the headless finisher asks the extractor for. [text], [state] and
/// [recentConversation] have already been through forget redaction.
class HeadlessExtraction {
  const HeadlessExtraction({
    required this.notebookId,
    required this.turnId,
    required this.text,
    required this.state,
    required this.recentConversation,
  });

  final String notebookId;
  final String turnId;
  final String text;
  final JournalState state;
  final List<({Speaker role, String text})> recentConversation;
}

/// Forget redaction (LM-63) for what leaves the phone. [TurnRedaction.of]
/// wraps the app's [ForgetRedactor]; [none] passes everything through.
class TurnRedaction {
  const TurnRedaction({
    Future<void> Function()? ensureLoaded,
    String Function(String text)? redact,
    JournalState Function(JournalState state)? redactState,
  })  : _ensureLoaded = ensureLoaded,
        _redact = redact,
        _redactState = redactState;

  factory TurnRedaction.of(ForgetRedactor redactor) => TurnRedaction(
        ensureLoaded: redactor.ensureLoaded,
        redact: redactor.redact,
        redactState: redactor.redactState,
      );

  static const TurnRedaction none = TurnRedaction();

  final Future<void> Function()? _ensureLoaded;
  final String Function(String text)? _redact;
  final JournalState Function(JournalState state)? _redactState;

  Future<void> ensureLoaded() => _ensureLoaded?.call() ?? Future.value();
  String redact(String text) => _redact?.call(text) ?? text;
  JournalState redactState(JournalState state) =>
      _redactState?.call(state) ?? state;
}

/// What [HeadlessTurnFinisher.finishNotebook] did. Ids only.
class NotebookFinishResult {
  const NotebookFinishResult({
    required this.notebookId,
    this.committedTurnIds = const [],
    this.rejectedTurnIds = const [],
    this.deferredTurnId,
    this.revision,
  });

  final String notebookId;

  /// Committed (or found already committed by the server ledger) and
  /// removed from the journal, in order.
  final List<String> committedTurnIds;

  /// Refused for good by the server and removed from the journal, as the
  /// open notebook drops them.
  final List<String> rejectedTurnIds;

  /// The turn that could not finish now. It and every later turn of the
  /// notebook stay journalled for the next catch-up.
  final String? deferredTurnId;

  /// The notebook's revision after the last commit, when one happened.
  final int? revision;

  bool get done => deferredTurnId == null;
}

enum _Finish { committed, rejected, deferred }

/// Commits a notebook's journalled turns without opening it (LM-103).
///
/// Per turn, from what the journal kept:
/// (a) a prepared commit: sent as it is, under the turn's `commitRequestId`;
/// (b) an extraction but no prepared commit: merged onto the server
///     snapshot, the envelope persisted, then sent;
/// (c) no extraction: extracted (keyed by turn id), checkpointed, then (b).
/// A conflict reloads the snapshot and rebases once; a second leaves the
/// turn for later. A thrown commit (unknown outcome) leaves the turn and
/// its envelope as they are, so the next try replays through the server
/// ledger. Turns go strictly in journal order, as the open notebook's queue
/// does; the first that cannot finish stops the notebook.
///
/// The caller must not run this for a notebook a live session has open:
/// that notebook's own queue is finishing the same turns.
class HeadlessTurnFinisher {
  HeadlessTurnFinisher({
    required TurnJournalService journal,
    required CommitNotebookFn commit,
    required LoadNotebookSnapshotFn loadSnapshot,
    required ExtractJournalTurnFn extract,
    TurnRedaction redaction = TurnRedaction.none,
  })  : _journal = journal,
        _commit = commit,
        _loadSnapshot = loadSnapshot,
        _extract = extract,
        _redaction = redaction;

  /// How many earlier turns go to the extractor as recent conversation.
  static const int recentTurns = 16;

  final TurnJournalService _journal;
  final CommitNotebookFn _commit;
  final LoadNotebookSnapshotFn _loadSnapshot;
  final ExtractJournalTurnFn _extract;
  final TurnRedaction _redaction;

  Future<NotebookFinishResult> finishNotebook(String notebookId) async {
    final checkpoints = await _journal.loadCheckpoints(notebookId);
    final committed = <String>[];
    final rejected = <String>[];
    final earlier = <FinalizedTurn>[];
    int? revision;

    for (final checkpoint in checkpoints) {
      final turnId = checkpoint.turn.turnId;
      final (outcome, at) = await _finishTurn(checkpoint, earlier);
      switch (outcome) {
        case _Finish.committed:
          committed.add(turnId);
          revision = at ?? revision;
        case _Finish.rejected:
          rejected.add(turnId);
        case _Finish.deferred:
          return NotebookFinishResult(
            notebookId: notebookId,
            committedTurnIds: committed,
            rejectedTurnIds: rejected,
            deferredTurnId: turnId,
            revision: revision,
          );
      }
      earlier.add(checkpoint.turn);
    }
    return NotebookFinishResult(
      notebookId: notebookId,
      committedTurnIds: committed,
      rejectedTurnIds: rejected,
      revision: revision,
    );
  }

  Future<(_Finish, int?)> _finishTurn(
    TurnJournalCheckpoint checkpoint,
    List<FinalizedTurn> earlier,
  ) async {
    var turn = checkpoint.turn;
    var prepared = checkpoint.preparedCommit;
    var rebased = false;

    try {
      if (prepared == null) {
        final made = await _prepare(turn, earlier);
        if (made == null) return (_Finish.deferred, null);
        (turn, prepared) = made;
      }

      while (true) {
        final outcome = await _commit(
          notebookId: turn.notebookId,
          expectedRevision: prepared!.expectedRevision,
          requestId: turn.commitRequestId,
          change: prepared.change,
        );
        switch (outcome) {
          case CommitCommitted(:final revision):
            await _journal.forgetTurn(
              notebookId: turn.notebookId,
              turnId: turn.turnId,
            );
            return (_Finish.committed, revision);
          case CommitConflict():
            // No write and no ledger row: the same request id stays valid
            // for a fresh merge on the current snapshot. Once.
            if (rebased) return (_Finish.deferred, null);
            rebased = true;
            final made = await _prepare(turn, earlier);
            if (made == null) return (_Finish.deferred, null);
            (turn, prepared) = made;
          case CommitRejected(:final code):
            vlog('catchup', 'commit rejected for turn ${turn.turnId}: $code');
            // notFound may be another account's notebook on this phone, and
            // commitFailed is the server's own trouble: both wait. Anything
            // else is refused for good, and dropped as the open notebook does.
            if (code == 'notFound' || code == 'commitFailed') {
              return (_Finish.deferred, null);
            }
            await _journal.forgetTurn(
              notebookId: turn.notebookId,
              turnId: turn.turnId,
            );
            return (_Finish.rejected, null);
        }
      }
    } catch (error) {
      // Unknown outcome or no network: the journal keeps the turn and any
      // envelope already persisted; the next try sends it unchanged.
      vlog(
          'catchup',
          'turn ${turn.turnId} left for later: '
              '${error.runtimeType}');
      return (_Finish.deferred, null);
    }
  }

  /// Loads the server snapshot, extracts if the turn has no result yet,
  /// merges, and persists the envelope before it is sent. Null when the
  /// notebook cannot be read now.
  Future<(FinalizedTurn, PreparedTurnCommit)?> _prepare(
    FinalizedTurn turn,
    List<FinalizedTurn> earlier,
  ) async {
    final snapshot = await _loadSnapshot(turn.notebookId);
    if (snapshot == null) return null;
    await _redaction.ensureLoaded();
    // As the open notebook adopts a snapshot: a forgotten person is gone
    // from what is merged onto, and from what the extractor is shown.
    final state = _redaction.redactState(snapshot.state);

    var patch = checkpointedPatch(turn);
    if (patch == null) {
      patch = await _extractFor(turn, state, earlier);
      turn = turn.copyWith(
        stage: DurableStage.extracted,
        extraction: patch.toJson(),
      );
      // Kept before anything else: a restart reuses this result rather than
      // asking again (and the runtime would refuse a changed input).
      await _journal.persistTurn(turn);
    }

    final result = prepareTurnCommit(
      state: state,
      turn: turn,
      patch: patch,
      expectedRevision: snapshot.revision,
    );
    turn = turn.copyWith(
      stage: DurableStage.commitPending,
      baseRevision: snapshot.revision,
    );
    await _journal.persistPreparedCommit(
      turn: turn,
      preparedCommit: result.prepared,
    );
    return (turn, result.prepared);
  }

  Future<GraphPatch> _extractFor(
    FinalizedTurn turn,
    JournalState state,
    List<FinalizedTurn> earlier,
  ) {
    if (!extractAssistantTurns && turn.speaker == Speaker.assistant) {
      return Future.value(GraphPatch.empty());
    }
    final recent = earlier.length > recentTurns
        ? earlier.sublist(earlier.length - recentTurns)
        : earlier;
    return _extract(HeadlessExtraction(
      notebookId: turn.notebookId,
      turnId: turn.turnId,
      text: _redaction.redact(turn.transcript),
      state: state,
      recentConversation: [
        for (final previous in recent)
          (
            role: previous.speaker,
            text: _redaction.redact(previous.transcript)
          ),
      ],
    ));
  }
}
