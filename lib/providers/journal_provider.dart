import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/pcm_capture.dart';
import '../audio/pcm_player.dart';
import '../logic/agenda.dart' as agenda_logic;
import '../logic/conversation_policy.dart';
import '../logic/live_session_guard.dart';
import '../logic/live_signal_gate.dart';
import '../logic/merge.dart' as merge_logic;
import '../logic/session_opening_coordinator.dart';
import '../logic/transcript_assembler.dart';
import '../logic/turn_effect_queue.dart';
import '../logic/turn_state.dart';
import '../logic/voice_log.dart';
import '../logic/warm_budget.dart';
import '../models/graph_patch.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/upsert_activity.dart';
import '../services/gemini_live_client.dart';
import '../services/notebook_commit_service.dart' as commit_service;
import '../services/notebook_runtime_service.dart';
import '../services/retrieve_memory_service.dart';
import '../services/turn_journal_service.dart';
import 'supabase_provider.dart';

enum SessionStatus { idle, connecting, live, ending, error }

class NotebookTransitionResult {
  const NotebookTransitionResult._(this.succeeded, [this.message]);

  const NotebookTransitionResult.success() : this._(true);

  const NotebookTransitionResult.failure(String message)
      : this._(false, message);

  final bool succeeded;
  final String? message;
}

/// Milliseconds to wait for an authoritative transcript after turn completion.
/// Gemini gives no ordering guarantee between the final input transcription and
/// the turn-completion signal, so a completed turn waits briefly rather than
/// finalizing on whatever interim text happened to have arrived.
const int finalizationDeadlineMs = 1500;

/// Bumped whenever the extractor prompt, schema or model changes. Recorded on
/// every finalized turn so a replayed checkpoint is never silently
/// reinterpreted by a different extractor than the one that produced it.
const String extractorVersion = 'gemini/extract_graph/v2';

class JournalNotifier extends Notifier<JournalState> {
  GeminiLiveClient? _live;
  PcmCapture? _capture;
  PcmPlayer? _player;
  final LiveSessionGuard _liveSessionGuard = LiveSessionGuard();
  Future<void> _lifecycleTail = Future<void>.value();
  int _lifecycleIntent = 0;

  /// One fallback per completed turn. User and assistant final transcripts can
  /// both lag provider completion, so a single shared timer is insufficient.
  final Map<String, Timer> _finalizationTimers = {};
  // Agenda input only (buildAgenda's lastUserText) — never cleared per turn,
  // so the UI must not read it. The dock reads the live fields below.
  String _lastTranscript = '';

  // Live, replaceable display text per speaker. Cleared the way the web's
  // use-gemini-live clears userTranscript/agentTranscript, so a finished turn
  // can never reappear as a pending bubble.
  String _liveUserText = '';
  String _liveAgentText = '';
  // Unfinished utterances (still transcribing, or awaiting the provider's
  // authoritative final), snapshotted with the conversation on every event.
  final _inProgress = <ConversationTurn>[];
  // Any finalized turn still waiting on extraction/commit (web: `thinking`).
  bool _extracting = false;
  UpsertActivity? _activity;
  int _activitySeq = 0;
  Timer? _activityTimer;
  static const _activityVisibleMs = 5200;

  /// Shared, platform-free turn rules. Identical to the web app's reducer.
  late final TurnMachine _turnMachine = TurnMachine(
    now: () => DateTime.now().toUtc().toIso8601String(),
    newTurnId: commit_service.NotebookCommitService.newRequestId,
    newRequestId: commit_service.NotebookCommitService.newRequestId,
    extractorVersion: extractorVersion,
  );
  final TranscriptAssembler _assembler = TranscriptAssembler();

  /// Extraction results held against their turn id until the commit succeeds.
  final Map<String, GraphPatch> _lastPatches = {};
  final Map<String, String> _checkpointNotebookByTurnId = {};

  /// Exact merge outputs held across unknown-outcome retries. Reusing the
  /// request id is safe only when the expected revision and change are also
  /// reused byte-for-byte/logically unchanged.
  final Map<String, PreparedTurnCommit> _preparedCommits = {};
  final Set<String> _restoredPreparedCommitIds = {};
  late final TurnEffectQueue _effectQueue = TurnEffectQueue(
    onFailure: (error, stackTrace) {
      vlog('session', 'turn effect failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    },
  );
  String? _restoredNotebookId;

  final _conversation = <ConversationTurn>[];
  String? _activeNotebookId;
  SessionStatus _status = SessionStatus.idle;
  DateTime? _sessionStartedAt;
  String? _lastMemoryQuery;
  int _memoryCallsThisTurn = 0;
  static const _maxMemoryCallsPerTurn = 3;
  bool _muted = false;
  // Driven by the player's playback clock (audio still queued ahead of the
  // listener), not by chunk arrival: Gemini streams faster than real time,
  // so its turn completes while Lumen is still audibly talking. The 400ms
  // arrival heuristic remains only as the fallback when playback is
  // unavailable.
  bool _agentSpeaking = false;
  Timer? _agentSpeakingTimer;
  static const _agentSpeakingIdleMs = 400;

  // Lumen's assistant turn completed while its audio was still playing; its
  // words stay on the pill until the voice actually stops.
  bool _agentTurnDone = false;

  // The live session's opening handshake: Lumen has the floor from the tap
  // until its opening has been heard. Null outside a session.
  SessionOpeningCoordinator? _opening;

  // Warm standby (see warmUp): a prepared session waiting for the tap.
  _PreparedLive? _warm;
  Timer? _warmRefreshTimer;
  bool _warmQueued = false;
  DateTime? _lastWarmFailureAt;
  final WarmBudget _warmBudget = WarmBudget();
  static const _warmRetryBackoff = Duration(seconds: 30);

  // Optimistic-concurrency counter from the last-known server snapshot.
  // Every commit reads this fresh (at the moment it actually runs, not when
  // it was queued) and a committed response updates it — see
  // _enqueueCommit / _commitApplyTurn.
  int _revision = 0;
  SessionStatus get status => _status;
  String get lastTranscript => _lastTranscript;
  String get liveUserText => _liveUserText;
  String get liveAgentText => _liveAgentText;

  /// The chat pane's rows: finalized turns plus unfinished utterances, in the
  /// order they were spoken. An utterance keeps its slot from first word to
  /// finalization, so nothing vanishes or jumps while Gemini's finals lag.
  List<TranscriptRow> get transcriptRows {
    final rows = <TranscriptRow>[
      for (final turn in conversation) (turn: turn, pending: false),
      for (final turn in inProgress) (turn: turn, pending: true),
    ];
    // List.sort is not guaranteed stable; break ties by original position.
    final indexed = rows.indexed.toList()
      ..sort((a, b) {
        final byTime = compareInstants(a.$2.turn.startedAt, b.$2.turn.startedAt);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
    return [for (final (_, row) in indexed) row];
  }
  bool get extracting => _extracting;
  UpsertActivity? get activity => _activity;
  List<ConversationTurn> get conversation => List.unmodifiable(_conversation);
  List<ConversationTurn> get inProgress => List.unmodifiable(_inProgress);
  bool get muted => _muted;
  bool get agentSpeaking => _agentSpeaking;

  /// Lumen owns the floor: the session is starting and its opening has not
  /// finished playing yet. The dock shows Lumen, never "You", meanwhile —
  /// user audio is not accepted until this clears.
  bool get openingInProgress =>
      _status == SessionStatus.connecting || (_opening?.inProgress ?? false);
  int get revision => _revision;

  @override
  JournalState build() {
    ref.onDispose(() {
      _liveSessionGuard.invalidate();
      for (final timer in _finalizationTimers.values) {
        timer.cancel();
      }
      _finalizationTimers.clear();
      _agentSpeakingTimer?.cancel();
      _activityTimer?.cancel();
      _warmRefreshTimer?.cancel();
      _warm?.gate.dispose();
      unawaited(_capture?.stop());
      unawaited(_live?.close());
      unawaited(_player?.dispose());
    });
    return JournalState.empty();
  }

  void _setStatus(SessionStatus status) {
    vlog('session', 'status → ${status.name}');
    _status = status;
    _notifyUi();
  }

  void toggleMute() {
    _muted = !_muted;
    _notifyUi();
  }

  /// The one place Lumen's speaking state changes. When the voice stops, a
  /// completed assistant turn's words leave the pill, and a finished opening
  /// hands the floor (and the mic) to the user.
  void _setAgentSpeaking(bool speaking) {
    if (_agentSpeaking == speaking) return;
    _agentSpeaking = speaking;
    if (!speaking) {
      if (_agentTurnDone) {
        _agentTurnDone = false;
        _liveAgentText = '';
      }
      if (_opening?.markOpeningHeard() ?? false) {
        vlog('session', 'opening heard — user turn enabled');
      }
    }
    _notifyUi();
  }

  // Fallback when there is no playback clock: talking until ~400ms after the
  // last audio chunk (reset on every chunk), or turn-complete/session-end.
  void _markAgentSpeaking() {
    _setAgentSpeaking(true);
    _agentSpeakingTimer?.cancel();
    _agentSpeakingTimer = Timer(
      const Duration(milliseconds: _agentSpeakingIdleMs),
      () {
        _agentSpeakingTimer = null;
        _setAgentSpeaking(false);
      },
    );
  }

  void _clearAgentSpeaking() {
    _agentSpeakingTimer?.cancel();
    _agentSpeakingTimer = null;
    _setAgentSpeaking(false);
  }

  void _setTranscript(String text) {
    _lastTranscript = text;
    _notifyUi();
  }

  void _notifyUi() {
    state = state.copyWith();
  }

  Future<T> _serializeLifecycle<T>(Future<T> Function() operation) {
    final result = _lifecycleTail.then<T>((_) => operation());
    _lifecycleTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  bool _isCurrentLiveSession(
    LiveSessionLease lease,
    GeminiLiveClient client,
  ) =>
      _liveSessionGuard.isCurrent(lease) &&
      identical(_live, client) &&
      _activeNotebookId == lease.notebookId;

  /// Feeds one adapter event into the shared turn machine and carries out the
  /// effects it asks for. The rules — one durable turn per finalized
  /// transcript, identity-checked async results, ordered replay after a
  /// conflict, one reused request id per turn — live in lib/logic/turn_state.dart
  /// and are the same rules the web app runs.
  void _dispatchTurn(TurnEvent event) {
    final effects = _turnMachine.dispatch(event);
    _trackLiveText(event);
    final durableEffects = <TurnEffect>[];
    for (final effect in effects) {
      if (effect is FlushPlayback) {
        // Interruption is latency-sensitive. Invalidate the current playback
        // source immediately instead of waiting behind extraction or commits.
        unawaited(_flushPlayback());
      } else if (effect is ScheduleFinalizationDeadline) {
        // Start the provider-ordering grace period immediately. Durable work
        // may already be queued and must not delay a transcript deadline.
        _scheduleFinalizationDeadline(effect);
      } else {
        durableEffects.add(effect);
      }
    }
    if (durableEffects.isNotEmpty) {
      _effectQueue.enqueue(() => _performEffects(durableEffects));
    }
    final latest = _turnMachine.state;
    _conversation
      ..clear()
      ..addAll(latest.conversation);
    _inProgress
      ..clear()
      ..addAll(_turnMachine.inProgress);
    _extracting = latest.pending.isNotEmpty;
    _notifyUi();
  }

  void _trackLiveText(TurnEvent event) {
    switch (event) {
      case InterimTranscript(speaker: Speaker.user, :final text):
        _liveUserText = text;
      case FinalTranscript(speaker: Speaker.user):
      case TurnCompleted(speaker: Speaker.user):
        _liveUserText = '';
      case InterimTranscript(speaker: Speaker.assistant, :final text):
        _liveAgentText = text;
        _agentTurnDone = false;
      case TurnCompleted(speaker: Speaker.assistant):
        // Keep Lumen's words on the pill until the voice actually stops.
        if (_agentSpeaking) {
          _agentTurnDone = true;
        } else {
          _liveAgentText = '';
        }
      case AssistantInterrupted():
        _liveAgentText = '';
        _agentTurnDone = false;
      case SessionEnded():
        _clearLiveText();
      default:
    }
  }

  void _clearLiveText() {
    _liveUserText = '';
    _liveAgentText = '';
    _agentTurnDone = false;
  }

  void _showActivity(UpsertActivity? activity) {
    if (activity == null) return;
    _activity = activity;
    _activityTimer?.cancel();
    _activityTimer = Timer(
      const Duration(milliseconds: _activityVisibleMs),
      () {
        _activityTimer = null;
        _activity = null;
        _notifyUi();
      },
    );
    _notifyUi();
  }

  void _scheduleFinalizationDeadline(ScheduleFinalizationDeadline effect) {
    final key = '${effect.speaker.name}:${effect.turnId}';
    _finalizationTimers.remove(key)?.cancel();
    _finalizationTimers[key] = Timer(
      const Duration(milliseconds: finalizationDeadlineMs),
      () {
        _finalizationTimers.remove(key);
        final generation = effect.transcriptGeneration;
        if (generation != null) {
          _assembler.expirePending(effect.speaker, generation);
        }
        _dispatchTurn(FinalizationDeadline(
          speaker: effect.speaker,
          turnId: effect.turnId,
        ));
      },
    );
  }

  Future<void> _performEffects(List<TurnEffect> effects) async {
    for (final effect in effects) {
      switch (effect) {
        case PersistTurn():
          await _persistTurn(effect.turn);
        case ForgetTurn():
          await _forgetTurn(effect.turnId);
        default:
          await _performEffect(effect);
      }
    }
  }

  Future<void> _performEffect(TurnEffect effect) async {
    switch (effect) {
      case StartDurableExtraction():
        await _runDurableExtraction(effect);
      case StartCommit():
        final turn = _turnMachine.state.pending
            .where((t) => t.turnId == effect.turnId)
            .firstOrNull;
        if (turn != null) await _runCommit(turn);
      case ScheduleFinalizationDeadline():
        throw StateError('Transcript deadlines must run on the realtime path');
      case ReloadSnapshot():
        await _reloadSnapshot();
      case FlushPlayback():
        throw StateError('Playback flushes must run on the realtime path');
      case CancelExtraction():
        // Cancellation is a resource optimisation only; the machine's identity
        // check is what decides whether a late result may change anything.
        break;
      case PersistTurn():
      case ForgetTurn():
        throw StateError(
            'Durable journal effects must run through the effect queue');
      case StartProvisionalExtraction():
        break;
    }
  }

  Future<void> _persistTurn(FinalizedTurn turn) async {
    await ref.read(turnJournalServiceProvider).persistTurn(turn);
    _checkpointNotebookByTurnId[turn.turnId] = turn.notebookId;
  }

  Future<void> _forgetTurn(String turnId) async {
    final notebookId =
        _checkpointNotebookByTurnId.remove(turnId) ?? _activeNotebookId;
    if (notebookId == null) return;
    await ref.read(turnJournalServiceProvider).forgetTurn(
          notebookId: notebookId,
          turnId: turnId,
        );
  }

  Future<void> _flushPlayback() async {
    try {
      await _player?.flush();
    } catch (error, stack) {
      vlog('playback', 'flush failed: $error');
      debugPrintStack(stackTrace: stack);
    } finally {
      _clearAgentSpeaking();
    }
  }

  Future<void> _restoreTurnsForNotebook(String notebookId) async {
    if (_restoredNotebookId == notebookId) return;

    try {
      final checkpoints = await ref
          .read(turnJournalServiceProvider)
          .loadCheckpoints(notebookId);
      final turns = checkpoints
          .map((checkpoint) => checkpoint.turn)
          .toList(growable: false);
      _restoredNotebookId = notebookId;
      for (final checkpoint in checkpoints) {
        final turn = checkpoint.turn;
        _checkpointNotebookByTurnId[turn.turnId] = turn.notebookId;
        final prepared = checkpoint.preparedCommit;
        if (prepared != null) {
          _preparedCommits[turn.turnId] = prepared;
          _restoredPreparedCommitIds.add(turn.turnId);
        }
      }

      // Establish notebook identity before Restored drives extraction or
      // commit effects. A later live socket replaces only the session id.
      _dispatchTurn(SessionStarted(
        sessionId:
            'recovery-${commit_service.NotebookCommitService.newRequestId()}',
        notebookId: notebookId,
        revision: _revision,
      ));
      if (turns.isNotEmpty) {
        _dispatchTurn(Restored(turns: turns));
      }
    } catch (error, stack) {
      _restoredNotebookId = null;
      vlog('session', 'turn journal restore failed: $error');
      debugPrintStack(stackTrace: stack);
    }
  }

  Future<void> _runDurableExtraction(StartDurableExtraction effect) async {
    final extractService = ref.read(extractGraphServiceProvider);
    try {
      final retrieval = await RetrieveMemoryService(
        ref.read(supabaseClientProvider),
      ).retrieveResult(
        query: effect.transcript,
        notebookId: effect.key.notebookId,
        state: state,
      );
      final openFollowUps = state.followUps.where((item) => !item.answered);
      final patch = await extractService.extract(
        notebookId: effect.key.notebookId,
        turnId: effect.key.turnId,
        extractorVersion: extractorVersion,
        text: effect.transcript,
        state: state,
        mode: 'granular',
        recentConversation: _conversation
            .map((turn) => (role: turn.role, text: turn.text))
            .toList(growable: false),
        retrievedEntityIds: retrieval.entityIds,
        answeringFollowUp: openFollowUps.isEmpty ? null : openFollowUps.last,
      );
      _lastPatches[effect.key.turnId] = patch;
      // The checkpoint carries the real result, not a marker: a restart must be
      // able to reuse exactly what the model returned.
      _dispatchTurn(DurableExtractionSucceeded(
        key: effect.key,
        payload: patch.toJson(),
      ));
    } catch (error) {
      vlog('session', 'durable extraction failed: $error');
      _dispatchTurn(
          DurableExtractionFailed(key: effect.key, message: '$error'));
    }
  }

  Future<void> _runCommit(FinalizedTurn turn) async {
    var prepared = _preparedCommits[turn.turnId];
    if (prepared == null) {
      try {
        // Prefer the in-memory typed patch; fall back to the durable checkpoint
        // so a restored turn commits without re-extracting.
        final stored = turn.extraction;
        final patch = _lastPatches[turn.turnId] ??
            (stored == null ? null : GraphPatch.fromJson(stored));
        if (patch == null) {
          _dispatchTurn(
              CommitRejected(turnId: turn.turnId, code: 'invalidRequest'));
          return;
        }

        // Prepare once. An unknown-outcome retry must reuse this exact envelope
        // instead of merging again against the already-optimistic local state.
        final before = state;
        final result = merge_logic.merge(state, turn.transcript, patch);
        prepared = PreparedTurnCommit(
          expectedRevision: turn.baseRevision ?? _revision,
          change: result.change,
          entryId: result.entryId,
        );
        // Persist the exact network envelope before sending it. If the process
        // dies after the request leaves, recovery must retry identical input
        // with the same request id so the server ledger can replay it safely.
        await ref.read(turnJournalServiceProvider).persistPreparedCommit(
              turn: turn,
              preparedCommit: prepared,
            );
        state = result.next;
        _preparedCommits[turn.turnId] = prepared;
        _showActivity(UpsertActivity.between(
          id: ++_activitySeq,
          prev: before,
          next: result.next,
          entryId: result.entryId,
        ));
        vlog(
            'session',
            'extract merged: ${state.entities.length} entities, '
                '${state.relations.length} relations');
      } catch (error, stack) {
        // Do not send a commit that cannot be reproduced after a crash.
        vlog('session', 'commit checkpoint failed: $error');
        debugPrintStack(stackTrace: stack);
        return;
      }
    }

    final commitService = ref.read(notebookCommitServiceProvider);
    commit_service.CommitOutcome outcome;
    try {
      outcome = await commitService.commitNotebook(
        notebookId: turn.notebookId,
        expectedRevision: prepared.expectedRevision,
        requestId: turn.commitRequestId,
        change: prepared.change,
      );
    } catch (error) {
      // Unknown outcome: retry the identical request with the same id. The
      // server ledger replays it if it already committed.
      vlog('session', 'commit RPC threw, retrying same requestId: $error');
      _dispatchTurn(CommitUnknown(turnId: turn.turnId));
      return;
    }

    if (outcome is commit_service.CommitCommitted) {
      _revision = outcome.revision;
      if (_restoredPreparedCommitIds.remove(turn.turnId)) {
        // A restored envelope has no corresponding optimistic state in this
        // process. Reload the committed server snapshot instead of attempting
        // to reconcile an entry id that exists only in the previous process.
        final snapshot =
            await commitService.getNotebookSnapshot(turn.notebookId);
        if (snapshot != null) {
          _revision = snapshot.revision;
          state = snapshot.state;
        }
      } else {
        _reconcileEntryId(prepared.entryId, outcome.entryId);
      }
      _preparedCommits.remove(turn.turnId);
      _lastPatches.remove(turn.turnId);
      _dispatchTurn(
          CommitCommitted(turnId: turn.turnId, revision: outcome.revision));
      return;
    }
    if (outcome is commit_service.CommitConflict) {
      // A confirmed conflict did not write or create a ledger row. Discard the
      // old envelope; after the snapshot reload, one fresh merge will rebase.
      _preparedCommits.remove(turn.turnId);
      _restoredPreparedCommitIds.remove(turn.turnId);
      _dispatchTurn(CommitConflict(
        turnId: turn.turnId,
        currentRevision: outcome.currentRevision,
      ));
      return;
    }
    if (outcome is commit_service.CommitRejected) {
      vlog('session', 'commit rejected: ${outcome.code}');
      _preparedCommits.remove(turn.turnId);
      _restoredPreparedCommitIds.remove(turn.turnId);
      _lastPatches.remove(turn.turnId);
      _dispatchTurn(CommitRejected(turnId: turn.turnId, code: outcome.code));
    }
  }

  void _reconcileEntryId(String localId, String? realId) {
    if (realId == null || realId == localId) return;
    final entries = state.entries
        .map((entry) => entry.id == localId
            ? JournalEntry(
                id: realId,
                text: entry.text,
                createdAt: entry.createdAt,
                entityIds: entry.entityIds,
                relationIds: entry.relationIds,
              )
            : entry)
        .toList();
    state = state.copyWith(entries: entries);
  }

  Future<void> _reloadSnapshot() async {
    final notebookId = _activeNotebookId;
    if (notebookId == null) return;
    try {
      final commitService = ref.read(notebookCommitServiceProvider);
      final snapshot = await commitService.getNotebookSnapshot(notebookId);
      if (snapshot == null) return;
      _revision = snapshot.revision;
      state = snapshot.state;
      // Pending turns now replay over the fresh snapshot in their original
      // order, keeping the request ids they were minted with.
      _dispatchTurn(SnapshotReloaded(revision: snapshot.revision));
    } catch (error) {
      vlog('session', 'snapshot reload failed: $error');
    }
  }

  // _enqueueCommit's promise-chaining queue is gone. Ordering is no longer an
  // adapter concern: the turn machine processes one pending turn at a time, in
  // the order the turns were spoken, and does not start the next durable step
  // until the current one resolves. The effect queue tracks every durable
  // adapter operation so shutdown can drain the whole chain to a fixed point.

  // _commitApplyTurn lived here. Commits are now driven by the shared turn
  // machine: it decides when a turn may be written, in what order, and with
  // which request id, and _runCommit performs the write. That removed this
  // method's bespoke "retry once, replacing the optimistic base" recovery in
  // favour of ordered replay over a freshly reloaded snapshot.

  Map<String, dynamic> _buildGraphSummary() {
    final agenda =
        agenda_logic.buildAgenda(state, lastUserText: _lastTranscript);
    final sessionElapsedMin = _sessionStartedAt == null
        ? 0
        : DateTime.now().difference(_sessionStartedAt!).inMinutes;
    return {
      'mode': 'granular',
      'entityCount': agenda.entityCount,
      'relationCount': agenda.relationCount,
      'entities': state.entities.values
          .map(
            (entity) => {
              'name': entity.name,
              'type': entity.type.name,
              'coverage': agenda.thinEntities.contains(entity.name)
                  ? 'thin'
                  : 'developing',
              'mentions': entity.mentions,
              'relationCount': state.relations.values
                  .where(
                    (relation) =>
                        relation.isActive &&
                        (relation.source == entity.id ||
                            relation.target == entity.id),
                  )
                  .length,
              'openQuestions': entity.questions ?? const <String>[],
            },
          )
          .toList(),
      'thinEntities': agenda.thinEntities.take(5).toList(),
      'justMentioned': agenda.justMentioned,
      'uncertainRelations': agenda.uncertainRelations
          .map(
            (relation) => {
              'source': relation.source,
              'label': relation.label,
              'target': relation.target,
              'score': relation.score,
            },
          )
          .toList(),
      'bridgeCandidates':
          agenda.bridgeCandidates.map((pair) => [pair.$1, pair.$2]).toList(),
      'openQuestionsTop': agenda.openQuestions
          .take(5)
          .map(
            (question) => {
              'entity': question.entity,
              'question': question.question,
            },
          )
          .toList(),
      'recentAgentQuestions': _conversation
          .where((turn) => turn.role == Speaker.assistant)
          .map((turn) => turn.text)
          .where((text) => text.isNotEmpty)
          .take(8)
          .toList(),
      'sessionElapsedMin': sessionElapsedMin,
    };
  }

  Future<Map<String, dynamic>> _retrieveMemory(
      Map<String, dynamic> args) async {
    final notebookId = _activeNotebookId;
    final query = (args['query'] as String?)?.trim() ?? '';
    // Over-call guardrails: tiny query, identical repeat (within turn), per-turn cap.
    if (notebookId == null ||
        query.length < 2 ||
        query == _lastMemoryQuery ||
        _memoryCallsThisTurn >= _maxMemoryCallsPerTurn) {
      return const {'context': ''};
    }
    _memoryCallsThisTurn++;
    _lastMemoryQuery = query;
    final service = RetrieveMemoryService(ref.read(supabaseClientProvider));
    final context = await service.retrieve(
      query: query,
      notebookId: notebookId,
      state: state,
    );
    return {'context': context};
  }

  Future<void> _loadNotebookUnlocked(String notebookId) async {
    final commitService = ref.read(notebookCommitServiceProvider);
    final snapshot = await commitService.getNotebookSnapshot(notebookId);
    _activeNotebookId = notebookId;
    _revision = snapshot?.revision ?? 0;
    state = snapshot?.state ?? JournalState.empty();
    await _restoreTurnsForNotebook(notebookId);
  }

  /// Safely leaves the current notebook before loading another one.
  ///
  /// This is the one notebook-transition interface for route callers. It keeps
  /// the previous notebook authoritative until its transport is closed and its
  /// durable work has drained, so callbacks from the old socket can never be
  /// interpreted under the new notebook id.
  Future<NotebookTransitionResult> enterNotebook(
    String notebookId, {
    bool autoStart = false,
  }) {
    final intent = ++_lifecycleIntent;
    if (_activeNotebookId != notebookId) {
      // Invalidate synchronously. The serialized transition may wait behind a
      // connecting session, but its already-queued callbacks become inert now.
      _liveSessionGuard.invalidate();
    }
    return _serializeLifecycle(() async {
      if (intent != _lifecycleIntent) {
        return const NotebookTransitionResult.failure(
          'Notebook transition was superseded by a newer request.',
        );
      }
      if (_activeNotebookId != null && _activeNotebookId != notebookId) {
        final left = await _leaveNotebookUnlocked();
        if (!left.succeeded) return left;
        if (intent != _lifecycleIntent) {
          return const NotebookTransitionResult.failure(
            'Notebook transition was superseded by a newer request.',
          );
        }
      }

      if (_activeNotebookId != notebookId) {
        try {
          await _loadNotebookUnlocked(notebookId);
        } catch (error, stack) {
          vlog('session', 'open notebook failed: $error');
          debugPrintStack(stackTrace: stack);
          return const NotebookTransitionResult.failure(
            'Could not open that notebook. Check your connection and try again.',
          );
        }
        if (intent != _lifecycleIntent) {
          return const NotebookTransitionResult.failure(
            'Notebook transition was superseded by a newer request.',
          );
        }
      }

      if (autoStart) return _startSessionUnlocked();
      // Queued behind this transition, so the caller isn't kept waiting.
      unawaited(warmUp());
      return const NotebookTransitionResult.success();
    });
  }

  /// Backwards-compatible safe entry point for callers that only load.
  Future<NotebookTransitionResult> openNotebook(String notebookId) =>
      enterNotebook(notebookId);

  Future<NotebookTransitionResult> startSession() {
    final intent = ++_lifecycleIntent;
    // Instant feedback: the dock shows "Lumen · Connecting" on the tap
    // itself, even while a warm-up or another lifecycle step finishes ahead
    // of this request in the serialized queue.
    if (_status == SessionStatus.idle || _status == SessionStatus.error) {
      _setStatus(SessionStatus.connecting);
    }
    return _serializeLifecycle(() {
      if (intent != _lifecycleIntent) {
        if (_status == SessionStatus.connecting && _live == null) {
          _setStatus(SessionStatus.idle);
        }
        return Future.value(
          const NotebookTransitionResult.failure(
            'Session start was superseded by a newer request.',
          ),
        );
      }
      return _startSessionUnlocked();
    });
  }

  // ─── Warm standby ─────────────────────────────────────────────────────────
  //
  // With a notebook open and no session running, everything a session needs
  // except the microphone is prepared ahead of the tap: audio session, the
  // runtime's single-use Gemini credential, the socket and its setup, the
  // player — and Lumen's opening is requested and buffered. The tap then
  // only starts capture and replays the buffered opening. Nothing from a
  // standby reaches the transcript, the turn machine or the speaker unless
  // the user taps; the mic is never opened by a warm-up.

  /// Prepares a standby session for the open notebook, if none is ready.
  Future<void> warmUp() {
    if (_warmQueued) return Future.value();
    _warmQueued = true;
    return _serializeLifecycle(_warmUnlocked);
  }

  /// Releases a standby session (e.g. the app went to the background).
  Future<void> coolDown() => _serializeLifecycle(() async {
        if (_warm != null && _status == SessionStatus.idle) {
          vlog('warm', 'cooling down standby session');
          await _closeLiveTransportUnlocked();
        }
      });

  /// The user touched the screen: refill the warm-up budget, and re-warm if
  /// the notebook went cold while idle.
  void noteInteraction() {
    _warmBudget.refill();
    if (_warm == null &&
        _status == SessionStatus.idle &&
        _activeNotebookId != null) {
      unawaited(warmUp());
    }
  }

  Future<void> _warmUnlocked() async {
    _warmQueued = false;
    if (_warm != null || _activeNotebookId == null) return;
    // A tap may already be waiting behind this warm-up (status connecting);
    // warming is still the fastest route to it, so only a running or ending
    // session stops us.
    if (_status != SessionStatus.idle && _status != SessionStatus.connecting) {
      return;
    }
    final failedAt = _lastWarmFailureAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _warmRetryBackoff) {
      return;
    }
    if (!_warmBudget.tryConsume()) {
      vlog('warm', 'budget spent — cold until the user interacts');
      return;
    }
    final lease = _liveSessionGuard.begin();
    try {
      final prepared = await _prepareLiveUnlocked(lease, standby: true);
      if (prepared == null) return;
      _warm = prepared;
      _lastWarmFailureAt = null;
      _warmRefreshTimer?.cancel();
      _warmRefreshTimer =
          Timer(WarmBudget.refreshAfter, () => _refreshWarm(prepared));
      vlog('warm', 'standby ready');
    } catch (error) {
      vlog('warm', 'standby failed, staying cold: $error');
      _lastWarmFailureAt = DateTime.now();
      if (_liveSessionGuard.isCurrent(lease)) {
        await _closeLiveTransportUnlocked();
      }
    }
  }

  /// Replaces a standby before Gemini closes it (timer or goAway).
  void _refreshWarm(_PreparedLive standby) {
    unawaited(_serializeLifecycle(() async {
      if (!identical(_warm, standby) || _status != SessionStatus.idle) return;
      vlog('warm', 'refreshing standby session');
      await _closeLiveTransportUnlocked();
      await _warmUnlocked();
    }));
  }

  /// Drops a standby whose socket failed. No error is shown — the user never
  /// asked for this session; the next tap simply takes the cold path.
  void _discardFailedWarm(_PreparedLive standby, Object error) {
    vlog('warm', 'standby dropped: $error');
    unawaited(_serializeLifecycle(() async {
      if (!identical(_warm, standby) || _status != SessionStatus.idle) return;
      _lastWarmFailureAt = DateTime.now();
      await _closeLiveTransportUnlocked();
    }));
  }

  // ─── Session start ────────────────────────────────────────────────────────

  Future<NotebookTransitionResult> _startSessionUnlocked() async {
    if (_status == SessionStatus.live) {
      return const NotebookTransitionResult.success();
    }
    _setStatus(SessionStatus.connecting);

    try {
      var prepared = _warm;
      if (prepared != null &&
          !_isCurrentLiveSession(prepared.binding, prepared.live)) {
        await _closeLiveTransportUnlocked();
        prepared = null;
      }
      if (prepared != null) {
        vlog('timing', 'tap → warm standby, activating');
      } else {
        final lease = _liveSessionGuard.begin();
        // Continue the notebook the dashboard opened (already loaded — no
        // reload on the critical path); otherwise fall back to the user's
        // active notebook, creating one if needed.
        if (_activeNotebookId == null) {
          final service = ref.read(supabaseServiceProvider);
          final notebook = await service.ensureActiveNotebook();
          if (!_liveSessionGuard.isCurrent(lease)) {
            return const NotebookTransitionResult.failure(
              'Session start was superseded by another notebook transition.',
            );
          }
          if (notebook == null) {
            throw StateError('No active notebook is available');
          }
          await _loadNotebookUnlocked(notebook.id);
        }
        vlog(
            'session',
            'notebook=$_activeNotebookId '
                '(${state.entities.length} entities loaded)');
        prepared = await _prepareLiveUnlocked(lease, standby: false);
        if (prepared == null) {
          return const NotebookTransitionResult.failure(
            'Session start was superseded by another notebook transition.',
          );
        }
      }
      return await _activateUnlocked(prepared);
    } catch (error, stack) {
      debugPrint('[journal] startSession failed: $error\n$stack');
      await _closeLiveTransportUnlocked();
      _setStatus(SessionStatus.error);
      return const NotebookTransitionResult.failure(
        'Could not start the session. Check your connection and try again.',
      );
    }
  }

  /// Everything a session needs except the microphone. Independent steps run
  /// in parallel; the socket needs the runtime's credential first. Returns
  /// null when a newer lifecycle request superseded this one.
  Future<_PreparedLive?> _prepareLiveUnlocked(
    LiveSessionLease lease, {
    required bool standby,
  }) async {
    final clock = Stopwatch()..start();
    void mark(String stage) =>
        vlog('timing', '${standby ? 'warm' : 'cold'} $stage '
            '+${clock.elapsedMilliseconds}ms');

    final notebookId = _activeNotebookId;
    if (notebookId == null) {
      throw StateError('No active notebook is available');
    }

    // Agent-audio playback is optional (the session still captures voice and
    // builds the graph without it), and its init can stall for minutes on
    // the simulator (just_audio / AVFoundation -11800) — so it runs in
    // parallel, timeout-capped and non-fatal, never in front of the socket.
    final player = PcmPlayer();
    _player = player;
    final audioSessionReady = _configureAudioSession();
    final playbackReady = _initPlayer(player);
    final liveSession = await ref
        .read(notebookRuntimeServiceProvider)
        .startLiveSession(notebookId);
    mark('credential');
    await audioSessionReady;
    if (!_liveSessionGuard.isCurrent(lease)) return null;
    if (liveSession is LiveSessionRejected) {
      throw StateError('Live session rejected: ${liveSession.code}');
    }
    final readySession = liveSession as LiveSessionReady;
    // The temporary Gemini credential authenticates the socket; it is not a
    // stable application identity. Mint a separate id for turn ownership and
    // stale-result checks within this live conversation.
    final conversationSessionId =
        commit_service.NotebookCommitService.newRequestId();
    final binding = lease.bind(
      notebookId: notebookId,
      sessionId: conversationSessionId,
    );

    final live = GeminiLiveClient(
      sessionToken: readySession.sessionToken,
      model: readySession.model,
      systemInstruction: geminiLiveSystemInstruction,
      voice: 'Aoede',
      tools: _liveTools,
    );
    final prepared = _PreparedLive(
      binding: binding,
      notebookId: notebookId,
      conversationSessionId: conversationSessionId,
      live: live,
      gate: LiveSignalGate(),
      opening: SessionOpeningCoordinator(),
    );
    bool isCurrent() => _isCurrentLiveSession(binding, live);
    void signal(LiveSignal value) {
      if (isCurrent()) prepared.gate.receive(value);
    }

    live
      // Every content signal goes through the gate: held while warm, paced
      // replay on activation, then straight through.
      ..onTranscript = (chunk, isFinal) {
        signal(UserTranscript(chunk, isFinal));
      }
      ..onAgentTranscript = (chunk, isFinal) {
        signal(AgentTranscript(chunk, isFinal));
      }
      ..onAudio = (pcm, sampleRate) {
        signal(AgentAudio(pcm, sampleRate));
      }
      ..onInterrupted = () {
        signal(const InterruptedSignal());
      }
      ..onTurnComplete = () {
        signal(const TurnCompleteSignal());
      }
      // Tool calls need answers now, warm or not; they only read the graph.
      ..onToolCall = (name, args) async {
        if (!isCurrent()) return const <String, dynamic>{};
        Map<String, dynamic> result;
        if (name == 'get_graph_summary') {
          result = _buildGraphSummary();
        } else if (name == 'get_relevant_memory') {
          result = await _retrieveMemory(args);
        } else {
          result = const {};
        }
        if (!isCurrent()) return const <String, dynamic>{};
        return result;
      }
      ..onGoAway = (timeLeft) {
        if (!isCurrent()) return;
        if (!prepared.gate.isActivated) {
          _refreshWarm(prepared);
        } else {
          vlog('session', 'Gemini will close this session in $timeLeft');
        }
      }
      ..onError = (error) {
        if (!isCurrent()) return;
        // A standby nobody asked for fails quietly; the next tap goes cold.
        if (standby && !prepared.gate.isActivated) {
          _discardFailedWarm(prepared, error);
          return;
        }
        debugPrint('[journal] Gemini Live error: $error');
        _setStatus(SessionStatus.error);
      };
    _live = live;

    await live.connect();
    await live.whenSetupComplete.timeout(const Duration(seconds: 8));
    if (!isCurrent()) return null;
    mark('setup complete');
    final playbackOk = await playbackReady;
    if (!isCurrent()) return null;
    if (!playbackOk && identical(_player, player)) _player = null;
    mark(playbackOk ? 'playback ready' : 'playback unavailable');

    // Lumen opens every session. Requested now, so a warm standby has the
    // opening buffered (or streaming) by the time the user taps.
    prepared.opening.markSetupComplete();
    if (prepared.opening.markPlaybackAttemptFinished()) {
      vlog('session', 'requesting Lumen opening turn');
      live.sendText(sessionOpeningPrimer);
    }
    return prepared;
  }

  /// The tap: the prepared session becomes the user's live session. The
  /// buffered opening replays at once (paced by its audio) and only then is
  /// the mic started — it stays gated until the opening has been heard.
  Future<NotebookTransitionResult> _activateUnlocked(
    _PreparedLive prepared,
  ) async {
    _warmRefreshTimer?.cancel();
    _warmRefreshTimer = null;
    _warm = null;
    bool isCurrent() => _isCurrentLiveSession(prepared.binding, prepared.live);

    _opening = prepared.opening;
    _sessionStartedAt = DateTime.now();
    // A live Gemini socket and an active turn-processing session are two
    // separate states. Establish the turn-machine identity before replaying
    // anything so transcripts can be finalized, extracted, and committed
    // against the loaded notebook revision.
    _dispatchTurn(SessionStarted(
      sessionId: prepared.conversationSessionId,
      notebookId: prepared.notebookId,
      revision: _revision,
    ));
    _setStatus(SessionStatus.live);
    vlog('timing', 'activated (${prepared.gate.buffered} signals buffered)');
    prepared.gate.activate((signal) {
      if (isCurrent()) _handleSignal(signal, prepared);
    });

    final capture = PcmCapture();
    _capture = capture;
    if (!await capture.hasPermission()) {
      debugPrint('[journal] microphone permission not granted');
      await _closeLiveTransportUnlocked();
      _setStatus(SessionStatus.error);
      return const NotebookTransitionResult.failure(
        'Microphone permission is required to start a journal session.',
      );
    }
    if (!isCurrent()) {
      await capture.stop();
      return const NotebookTransitionResult.failure(
        'Session start was superseded by another notebook transition.',
      );
    }
    await capture.start((pcm) {
      if (isCurrent() && prepared.opening.acceptsUserAudio) {
        prepared.live.sendAudio(pcm);
      }
    });
    if (!isCurrent()) {
      await capture.stop();
      return const NotebookTransitionResult.failure(
        'Session start was superseded by another notebook transition.',
      );
    }
    vlog('session', 'mic capture started');
    return const NotebookTransitionResult.success();
  }

  /// One Gemini signal, now that the session is the user's.
  void _handleSignal(LiveSignal signal, _PreparedLive prepared) {
    switch (signal) {
      // Meaningful transcript events, not cumulative sentence callbacks:
      // interim text is replaceable, and only a finalized, immutable
      // transcript may reach the graph.
      case UserTranscript(:final text, :final isFinal):
        if (text.isEmpty && !isFinal) return;
        final events =
            isFinal ? _assembler.userFinal(text) : _assembler.userChunk(text);
        for (final event in events) {
          if (event is InterimTranscript) _setTranscript(event.text);
          _dispatchTurn(event);
        }
      case AgentTranscript(:final text, :final isFinal):
        final events = isFinal
            ? _assembler.assistantFinal(text)
            : _assembler.assistantChunk(text);
        for (final event in events) {
          _dispatchTurn(event);
        }
      case AgentAudio(:final pcm, :final sampleRate):
        // Muted audio still runs the playback clock, so the dock keeps
        // showing that Lumen has the floor.
        final fed = _player?.feed(
              pcm,
              sampleRate: sampleRate,
              audible: !_muted,
            ) ??
            false;
        if (!fed) _markAgentSpeaking();
      case InterruptedSignal():
        // Gemini supplies audio and transcription without a trustworthy
        // word-level alignment. Queuing PCM therefore cannot prove any text
        // was physically heard. The null boundary safely skips durable
        // extraction for this interrupted assistant turn, while the emitted
        // FlushPlayback effect discards the queued audio.
        for (final event in _assembler.interrupted(null)) {
          _dispatchTurn(event);
        }
      case TurnCompleteSignal():
        _memoryCallsThisTurn = 0;
        _lastMemoryQuery = null;
        for (final event in _assembler.turnComplete()) {
          _dispatchTurn(event);
        }
        // With a playback clock, Lumen stops "speaking" when its queued
        // audio drains — usually seconds after Gemini's turn completes.
        if (_player == null) _clearAgentSpeaking();
        final opening = prepared.opening;
        if (opening.markTurnComplete()) {
          vlog('session', 'opening generated — waiting for it to be heard');
          if (!_agentSpeaking && opening.markOpeningHeard()) {
            vlog('session', 'opening heard — user turn enabled');
          }
        }
    }
  }

  // Configure the shared iOS audio session for simultaneous playback AND
  // recording before any audio component starts. Without this, just_audio
  // sets a playback-only category and the record plugin (which doesn't
  // manage the session by default) taps a mic the session can't record
  // from — the classic "dock listens, hears nothing" failure on device.
  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker |
                AVAudioSessionCategoryOptions.allowBluetooth,
        avAudioSessionMode: AVAudioSessionMode.spokenAudio,
      ));
    } catch (error) {
      debugPrint('[journal] audio session config unavailable: $error');
    }
  }

  /// Initializes [player] and wires its playback clock to the dock. False
  /// (and the player disposed) when playback is unavailable.
  Future<bool> _initPlayer(PcmPlayer player) async {
    try {
      await player.init().timeout(const Duration(seconds: 5));
      // A failed start may have torn the session down mid-init.
      if (player.isDisposed) return false;
      player.speaking.addListener(() {
        if (identical(_player, player)) {
          _setAgentSpeaking(player.speaking.value);
        }
      });
      vlog('playback', 'agent-audio playback ready');
      return true;
    } catch (error) {
      debugPrint('[journal] agent-audio playback unavailable, continuing '
          'without it: $error');
      unawaited(player.dispose().catchError((_) {}));
      return false;
    }
  }

  static const _liveTools = [
    {
      'function_declarations': [
        {
          'name': 'get_graph_summary',
          'description':
              'Returns the current knowledge graph state and agenda for the agent to plan its next question.',
          'parameters': {'type': 'object', 'properties': {}},
        },
        {
          'name': 'get_relevant_memory',
          'description':
              'Retrieve past memory relevant to a query: related entities and how they connect. Use when the user references something from earlier, or when grounding your reply in prior context would help. Distinct from get_graph_summary. For planning only — never read aloud.',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description':
                    'A few words to recall: a name, a topic, or a phrase.',
              },
            },
            'required': ['query'],
          },
        },
      ],
    },
  ];

  /// Waits until the tracked effect tail stops growing and the turn machine
  /// has no durable work left. Completing one effect may dispatch the next,
  /// so a single await of the current tail is not sufficient.
  Future<TurnEffectDrainOutcome> drain({
    Duration timeout = const Duration(seconds: 15),
  }) {
    return _effectQueue.drain(
      hasPendingWork: () => _turnMachine.state.pending.isNotEmpty,
      timeout: timeout,
    );
  }

  Future<void> _closeLiveTransportUnlocked() async {
    // Invalidate before the first await. A socket or microphone callback may
    // already be queued even though resource shutdown has started.
    _liveSessionGuard.invalidate();
    for (final timer in _finalizationTimers.values) {
      timer.cancel();
    }
    _finalizationTimers.clear();
    _clearAgentSpeaking();
    _clearLiveText();
    _opening = null;
    _warmRefreshTimer?.cancel();
    _warmRefreshTimer = null;
    _warm?.gate.dispose();
    _warm = null;

    final capture = _capture;
    final live = _live;
    final player = _player;
    _capture = null;
    _live = null;
    _player = null;

    try {
      await capture?.stop();
    } catch (error, stack) {
      vlog('session', 'mic shutdown failed: $error');
      debugPrintStack(stackTrace: stack);
    }
    try {
      await live?.close();
    } catch (error, stack) {
      vlog('session', 'live transport shutdown failed: $error');
      debugPrintStack(stackTrace: stack);
    }
    try {
      await player?.dispose();
    } catch (error, stack) {
      vlog('playback', 'player shutdown failed: $error');
      debugPrintStack(stackTrace: stack);
    }
    _assembler.reset();
  }

  /// Stops realtime input, drains notebook-scoped writes, and then releases
  /// the active notebook identity. Callers may navigate only after success.
  Future<NotebookTransitionResult> leaveNotebook() {
    // The operation itself is serialized, but stale realtime callbacks must be
    // rejected immediately while it waits for an in-progress start operation.
    final intent = ++_lifecycleIntent;
    _liveSessionGuard.invalidate();
    return _serializeLifecycle(() {
      if (intent != _lifecycleIntent) {
        return Future.value(
          const NotebookTransitionResult.failure(
            'Notebook transition was superseded by a newer request.',
          ),
        );
      }
      return _leaveNotebookUnlocked();
    });
  }

  Future<NotebookTransitionResult> endSession() => leaveNotebook();

  Future<NotebookTransitionResult> _leaveNotebookUnlocked() async {
    final notebookId = _activeNotebookId;
    final shouldEndNotebook = _sessionStartedAt != null;
    if (notebookId == null && _status == SessionStatus.idle) {
      return const NotebookTransitionResult.success();
    }

    _setStatus(SessionStatus.ending);
    await _closeLiveTransportUnlocked();
    _dispatchTurn(const SessionEnded());

    if (notebookId != null) {
      final outcome = await drain();
      if (!outcome.isCompleted) {
        // The live input is closed, but the notebook identity and durable
        // checkpoints stay intact. A later retry can finish the same work;
        // marking the notebook ended here would strand pending turns.
        vlog(
          'session',
          'notebook end deferred: ${outcome.status.name}'
              '${outcome.error == null ? '' : ' (${outcome.error})'}',
        );
        _muted = false;
        _setStatus(SessionStatus.error);
        return const NotebookTransitionResult.failure(
          'Your latest journal changes are still saving. Try leaving again.',
        );
      }
      if (shouldEndNotebook) {
        try {
          final service = ref.read(supabaseServiceProvider);
          await service.endNotebook(notebookId);
        } catch (error, stack) {
          vlog('session', 'notebook end failed: $error');
          debugPrintStack(stackTrace: stack);
          _muted = false;
          _setStatus(SessionStatus.error);
          return const NotebookTransitionResult.failure(
            'Your journal was saved, but the session could not be closed. '
            'Try leaving again.',
          );
        }
      }
    }

    _muted = false;
    _sessionStartedAt = null;
    _activeNotebookId = null;
    _restoredNotebookId = null;
    _lastTranscript = '';
    _lastMemoryQuery = null;
    _memoryCallsThisTurn = 0;
    _setStatus(SessionStatus.idle);
    return const NotebookTransitionResult.success();
  }
}

/// A connected, set-up Gemini session: a warm standby until [gate] is
/// activated, then the user's live session.
class _PreparedLive {
  _PreparedLive({
    required this.binding,
    required this.notebookId,
    required this.conversationSessionId,
    required this.live,
    required this.gate,
    required this.opening,
  });

  final LiveSessionLease binding;
  final String notebookId;
  final String conversationSessionId;
  final GeminiLiveClient live;
  final LiveSignalGate gate;
  final SessionOpeningCoordinator opening;
}

/// One chat-pane row: a conversation turn, and whether it is still unfinished.
typedef TranscriptRow = ({ConversationTurn turn, bool pending});

final turnJournalServiceProvider = Provider<TurnJournalService>((ref) {
  return TurnJournalService();
});

final journalProvider = NotifierProvider<JournalNotifier, JournalState>(
  JournalNotifier.new,
);
