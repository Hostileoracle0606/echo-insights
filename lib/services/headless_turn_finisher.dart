import '../logic/conversation_policy.dart' show extractAssistantTurns;
import '../logic/forget_redaction.dart';
import '../logic/turn_commit.dart';
import '../logic/turn_state.dart' show DurableStage, FinalizedTurn, Speaker;
import '../logic/voice_log.dart';
import '../models/graph_patch.dart';
import '../models/journal_state.dart';
import 'extract_graph_service.dart' show GraphExtractionException;
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
    this.notFound = false,
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

  /// The server did not find the notebook for this account in this run.
  /// Its turns are kept; the finisher skips it until the next run.
  final bool notFound;

  bool get done => deferredTurnId == null;
}

enum _Finish { committed, rejected, deferred, notFound }

/// Why [HeadlessTurnFinisher._prepare] could not make an envelope.
enum _NotPrepared { deferred, notFound }

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
/// Unlike the open notebook, which drops a turn on the first failed
/// extraction or refused commit, this defers: the turn stays journalled for
/// the next catch-up. To keep one stuck turn from blocking the notebook for
/// good, refusals are counted on the checkpoint and bounded by
/// [maxAttempts]:
/// - extraction refused as `requestIdReused` (the runtime holds a different
///   input under this turn id), or definitely refused [maxAttempts] times
///   (a 4xx other than 408, 429 and 409 `inProgress`): the turn is
///   committed with an empty patch, so its words are kept as an entry and
///   later turns go on. An outage (5xx, 429, 408, 409 `inProgress`), a
///   network failure or a malformed answer is delay, not a refusal: it is
///   not counted, so graph data is never given up for it.
/// - commit refused as `commitFailed` [maxAttempts] times: one last try
///   with an empty patch (the words kept as an entry; `commitFailed` writes
///   no ledger row, so the request id is still free). Dropped only if the
///   envelope is already empty, or that try is refused for good too.
/// - a notebook the server does not find (null snapshot, or `notFound`):
///   never dropped (it may be another account's on a shared phone, and
///   design for delay, not loss). The turn is deferred and the notebook
///   is skipped for the rest of this finisher's run: one server attempt
///   per notebook per run.
///
/// One instance is one catch-up run: build a fresh one for each run.
///
/// The caller must not run this for a notebook a live session has open:
/// that notebook's own queue is finishing the same turns.
class HeadlessTurnFinisher {
  HeadlessTurnFinisher({
    required TurnJournalService journal,
    required CommitNotebookFn commit,
    required LoadNotebookSnapshotFn loadSnapshot,
    required ExtractJournalTurnFn extract,
    required TurnRedaction redaction,
  })  : _journal = journal,
        _commit = commit,
        _loadSnapshot = loadSnapshot,
        _extract = extract,
        _redaction = redaction;

  /// How many earlier turns go to the extractor as recent conversation.
  ///
  /// Only turns still in the journal can be sent: turns already committed
  /// are not re-read from the server, and nothing Lumen said that the
  /// journal did not keep is included. So a headless extraction sees less
  /// context than the live one did (no retrieved entities, no follow-up
  /// being answered). This matters only when the runtime has no cached
  /// result for the turn id.
  static const int recentTurns = 16;

  /// Refusals of one step of a turn before catch-up stops asking.
  static const int maxAttempts = 3;

  final TurnJournalService _journal;
  final CommitNotebookFn _commit;
  final LoadNotebookSnapshotFn _loadSnapshot;
  final ExtractJournalTurnFn _extract;
  final TurnRedaction _redaction;

  /// Notebooks the server did not find during this run.
  final Set<String> _notFoundThisRun = {};

  Future<NotebookFinishResult> finishNotebook(String notebookId) async {
    final checkpoints = await _journal.loadCheckpoints(notebookId);
    if (checkpoints.isNotEmpty && _notFoundThisRun.contains(notebookId)) {
      return NotebookFinishResult(
        notebookId: notebookId,
        deferredTurnId: checkpoints.first.turn.turnId,
        notFound: true,
      );
    }
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
        case _Finish.notFound:
          final notFound = outcome == _Finish.notFound;
          if (notFound) _notFoundThisRun.add(notebookId);
          return NotebookFinishResult(
            notebookId: notebookId,
            committedTurnIds: committed,
            rejectedTurnIds: rejected,
            deferredTurnId: turnId,
            revision: revision,
            notFound: notFound,
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
        switch (await _prepare(turn, earlier)) {
          case (_NotPrepared reason, _):
            return (_settle(reason), null);
          case (_, (FinalizedTurn, PreparedTurnCommit) made):
            (turn, prepared) = made;
        }
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
            await _forget(turn);
            return (_Finish.committed, revision);
          case CommitConflict():
            // No write and no ledger row: the same request id stays valid
            // for a fresh merge on the current snapshot. Once.
            if (rebased) return (_Finish.deferred, null);
            rebased = true;
            switch (await _prepare(turn, earlier)) {
              case (_NotPrepared reason, _):
                return (_settle(reason), null);
              case (_, (FinalizedTurn, PreparedTurnCommit) made):
                (turn, prepared) = made;
            }
          case CommitRejected(:final code):
            vlog('catchup', 'commit rejected for turn ${turn.turnId}: $code');
            // Kept, never dropped: see the class comment.
            if (code == 'notFound') return (_Finish.notFound, null);
            if (code == 'commitFailed') {
              final count = await _journal.countAttempt(
                notebookId: turn.notebookId,
                turnId: turn.turnId,
                kind: TurnStepKind.commit,
              );
              if (count < maxAttempts) return (_Finish.deferred, null);
              if (!_isEmptyPatch(checkpointedPatch(turn))) {
                // Last try: the words alone, nothing for the graph.
                vlog('catchup', 'turn ${turn.turnId} retried without graph');
                turn = turn.copyWith(extraction: GraphPatch.empty().toJson());
                await _journal.persistTurn(turn);
                switch (await _prepare(turn, earlier)) {
                  case (_NotPrepared reason, _):
                    return (_settle(reason), null);
                  case (_, (FinalizedTurn, PreparedTurnCommit) made):
                    (turn, prepared) = made;
                }
                continue;
              }
              vlog('catchup',
                  'turn ${turn.turnId} dropped after $count refusals');
            }
            // Refused for good: dropped, as the open notebook does.
            await _forget(turn);
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

  Future<void> _forget(FinalizedTurn turn) => _journal.forgetTurn(
        notebookId: turn.notebookId,
        turnId: turn.turnId,
      );

  /// A turn that could not be prepared is always kept for later.
  static _Finish _settle(_NotPrepared reason) => switch (reason) {
        _NotPrepared.deferred => _Finish.deferred,
        _NotPrepared.notFound => _Finish.notFound,
      };

  /// Loads the server snapshot, extracts if the turn has no result yet,
  /// merges, and persists the envelope before it is sent.
  Future<(_NotPrepared?, (FinalizedTurn, PreparedTurnCommit)?)> _prepare(
    FinalizedTurn turn,
    List<FinalizedTurn> earlier,
  ) async {
    final snapshot = await _loadSnapshot(turn.notebookId);
    // Null is the server's answer (not found for this account), not a
    // network failure, which throws.
    if (snapshot == null) return (_NotPrepared.notFound, null);
    await _redaction.ensureLoaded();
    // As the open notebook adopts a snapshot: a forgotten person is gone
    // from what is merged onto, and from what the extractor is shown.
    final state = _redaction.redactState(snapshot.state);

    var patch = checkpointedPatch(turn);
    if (patch == null) {
      try {
        patch = await _extractFor(turn, state, earlier);
      } on Exception catch (error) {
        if (!_isRefusal(error)) rethrow;
        final reused = error is GraphExtractionException &&
            error.code == 'requestIdReused';
        if (!reused) {
          final count = await _journal.countAttempt(
            notebookId: turn.notebookId,
            turnId: turn.turnId,
            kind: TurnStepKind.extract,
          );
          if (count < maxAttempts) return (_NotPrepared.deferred, null);
        }
        // Kept as an entry with nothing added to the graph, so the words
        // are not lost and later turns are not held behind this one.
        vlog('catchup', 'turn ${turn.turnId} committed without extraction');
        patch = GraphPatch.empty();
      }
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
    return (null, (turn, result.prepared));
  }

  /// A definite refusal by the runtime: a 4xx other than 408 (timeout),
  /// 429 (rate limit) and 409 `inProgress` (another call owns the turn).
  /// An outage, a network failure, a signed-out session or a malformed
  /// answer is delay, and is not counted.
  static bool _isRefusal(Exception error) {
    if (error is! GraphExtractionException) return false;
    final status = error.statusCode;
    if (status == null || status < 400 || status >= 500) return false;
    if (status == 408 || status == 429) return false;
    return !(status == 409 && error.code == 'inProgress');
  }

  static bool _isEmptyPatch(GraphPatch? patch) =>
      patch != null &&
      patch.entities.isEmpty &&
      patch.relations.isEmpty &&
      patch.supersedes.isEmpty;

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
