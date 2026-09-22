import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/mic_controller.dart';
import '../audio/pcm_capture.dart';
import '../audio/pcm_player.dart';
import '../logic/agenda.dart' as agenda_logic;
import '../logic/conversation_policy.dart';
import '../logic/live_session_guard.dart';
import '../logic/merge.dart' as merge_logic;
import '../logic/transcript_assembler.dart';
import '../logic/turn_effect_queue.dart';
import '../logic/turn_state.dart';
import '../logic/voice_log.dart';
import '../models/graph_patch.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../services/gemini_live_client.dart';
import '../services/mic_permission_service.dart';
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
  MicController? _mic;
  PcmPlayer? _player;
  // Interruption / route-change subscriptions for the live session, and
  // whether this session activated the shared AVAudioSession (so close
  // releases it and other apps' audio can resume).
  final List<StreamSubscription<Object?>> _audioSessionSubs = [];
  bool _audioSessionActive = false;
  final LiveSessionGuard _liveSessionGuard = LiveSessionGuard();
  Future<void> _lifecycleTail = Future<void>.value();
  int _lifecycleIntent = 0;

  /// One fallback per completed turn. User and assistant final transcripts can
  /// both lag provider completion, so a single shared timer is insufficient.
  final Map<String, Timer> _finalizationTimers = {};
  String _lastTranscript = '';

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
      vlogStack(stackTrace);
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
  // Microphone permission was permanently denied: only Settings can fix it,
  // so the journal screen shows a persistent route there instead of a toast.
  bool _micBlocked = false;
  bool _agentSpeaking = false;
  Timer? _agentSpeakingTimer;
  static const _agentSpeakingIdleMs = 400;

  // Optimistic-concurrency counter from the last-known server snapshot.
  // Every commit reads this fresh (at the moment it actually runs, not when
  // it was queued) and a committed response updates it — see
  // _enqueueCommit / _commitApplyTurn.
  int _revision = 0;
  SessionStatus get status => _status;
  String get lastTranscript => _lastTranscript;
  List<ConversationTurn> get conversation => List.unmodifiable(_conversation);
  bool get muted => _muted;
  bool get micBlocked => _micBlocked;
  bool get agentSpeaking => _agentSpeaking;
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
      for (final sub in _audioSessionSubs) {
        unawaited(sub.cancel());
      }
      _audioSessionSubs.clear();
      unawaited(_mic?.stop() ?? _capture?.stop());
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

  // Marks Lumen as currently talking; cleared ~400ms after the last audio
  // chunk (reset on every chunk) or immediately on turn-complete/session-end,
  // whichever comes first.
  void _markAgentSpeaking() {
    if (!_agentSpeaking) {
      _agentSpeaking = true;
      _notifyUi();
    }
    _agentSpeakingTimer?.cancel();
    _agentSpeakingTimer = Timer(
      const Duration(milliseconds: _agentSpeakingIdleMs),
      () {
        _agentSpeakingTimer = null;
        if (_agentSpeaking) {
          _agentSpeaking = false;
          _notifyUi();
        }
      },
    );
  }

  void _clearAgentSpeaking() {
    _agentSpeakingTimer?.cancel();
    _agentSpeakingTimer = null;
    if (_agentSpeaking) {
      _agentSpeaking = false;
      _notifyUi();
    }
  }

  void _setTranscript(String text) {
    _lastTranscript = text;
    _notifyUi();
  }

  void _notifyUi() {
    state = state.copyWith();
  }

  /// Forwarded from LumenApp's AppLifecycleListener. There is deliberately no
  /// teardown on `paused`: UIBackgroundModes audio keeps an active session
  /// recording with the screen locked.
  void handleAppLifecycle(AppLifecycleState lifecycle) {
    switch (lifecycle) {
      case AppLifecycleState.paused:
        vlog('session', 'app backgrounded; session ${_status.name}');
      case AppLifecycleState.detached:
        // The app is being torn down (swiped away from the app switcher):
        // close the socket and mic and end the notebook rather than leave it
        // open. A no-op when nothing is active.
        vlog('session', 'app detached; ending session');
        unawaited(endSession());
      case AppLifecycleState.resumed:
        _reconcileAfterResume();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        break;
    }
  }

  /// Foregrounded again: state may have moved while no frames were drawn.
  /// Retry a mic still suspended by an interruption that ended without
  /// shouldResume, then repaint from the notifier's actual state.
  void _reconcileAfterResume() {
    final mic = _mic;
    if (_status == SessionStatus.live && mic != null && mic.suspended) {
      vlog('session', 'resuming mic suspended by an interruption');
      unawaited(mic.resume());
    }
    if (_micBlocked) unawaited(_refreshMicPermission());
    _notifyUi();
  }

  /// After a trip to Settings, clear the blocked state if access was granted.
  Future<void> _refreshMicPermission() async {
    try {
      final permission = await ref.read(micPermissionServiceProvider).status();
      if (permission == MicPermission.granted && _micBlocked) {
        _micBlocked = false;
        _notifyUi();
      }
    } catch (error) {
      vlog('session', 'microphone permission check failed: $error');
    }
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
      vlogStack(stack);
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
      vlogStack(stack);
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
        vlog(
            'session',
            'extract merged: ${state.entities.length} entities, '
                '${state.relations.length} relations');
      } catch (error, stack) {
        // Do not send a commit that cannot be reproduced after a crash.
        vlog('session', 'commit checkpoint failed: $error');
        vlogStack(stack);
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
          vlogStack(stack);
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
      return const NotebookTransitionResult.success();
    });
  }

  /// Backwards-compatible safe entry point for callers that only load.
  Future<NotebookTransitionResult> openNotebook(String notebookId) =>
      enterNotebook(notebookId);

  Future<NotebookTransitionResult> startSession() {
    final intent = ++_lifecycleIntent;
    return _serializeLifecycle(() {
      if (intent != _lifecycleIntent) {
        return Future.value(
          const NotebookTransitionResult.failure(
            'Session start was superseded by a newer request.',
          ),
        );
      }
      return _startSessionUnlocked();
    });
  }

  Future<NotebookTransitionResult> _startSessionUnlocked() async {
    if (_status == SessionStatus.connecting || _status == SessionStatus.live) {
      return const NotebookTransitionResult.success();
    }
    final lease = _liveSessionGuard.begin();
    _setStatus(SessionStatus.connecting);
    _sessionStartedAt = DateTime.now();

    try {
      final service = ref.read(supabaseServiceProvider);
      // Continue the notebook the dashboard opened; otherwise fall back to the
      // user's active notebook (creating one if needed).
      if (_activeNotebookId == null) {
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
      } else {
        await _loadNotebookUnlocked(_activeNotebookId!);
      }
      if (!_liveSessionGuard.isCurrent(lease)) {
        return const NotebookTransitionResult.failure(
          'Session start was superseded by another notebook transition.',
        );
      }
      vlog(
          'session',
          'notebook=$_activeNotebookId '
              '(${state.entities.length} entities loaded)');

      // Configure the shared iOS audio session for simultaneous playback AND
      // recording before any audio component starts. Without this, just_audio
      // sets a playback-only category and the record plugin (which doesn't
      // manage the session by default) taps a mic the session can't record
      // from — the classic "dock listens, hears nothing" failure on device.
      try {
        final session = await AudioSession.instance;
        await session.configure(AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.defaultToSpeaker |
                  AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: AVAudioSessionMode.spokenAudio,
        ));
        // Activate explicitly rather than relying on the implicit activation
        // inside just_audio / record: that path is not sufficient once the
        // app is backgrounded (UIBackgroundModes: audio).
        await session.setActive(true);
        _audioSessionActive = true;
      } catch (error) {
        jlog('audio session config unavailable: $error');
      }
      if (!_liveSessionGuard.isCurrent(lease)) {
        return const NotebookTransitionResult.failure(
          'Session start was superseded by another notebook transition.',
        );
      }

      // Permission comes before the live-session token is minted and before
      // the socket opens, so a denial never burns a credential.
      final permission =
          await ref.read(micPermissionServiceProvider).request();
      if (!_liveSessionGuard.isCurrent(lease)) {
        return const NotebookTransitionResult.failure(
          'Session start was superseded by another notebook transition.',
        );
      }
      _micBlocked = permission == MicPermission.permanentlyDenied;
      if (permission != MicPermission.granted) {
        vlog('session', 'microphone permission ${permission.name}');
        await _closeLiveTransportUnlocked();
        _setStatus(SessionStatus.error);
        return const NotebookTransitionResult.failure(
          'Microphone permission is required to start a journal session.',
        );
      }

      final notebookId = _activeNotebookId;
      if (notebookId == null) {
        throw StateError('No active notebook is available');
      }
      final liveSession = await ref
          .read(notebookRuntimeServiceProvider)
          .startLiveSession(notebookId);
      if (!_liveSessionGuard.isCurrent(lease)) {
        return const NotebookTransitionResult.failure(
          'Session start was superseded by another notebook transition.',
        );
      }
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
        tools: [
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
        ],
      );
      bool isCurrent() => _isCurrentLiveSession(binding, live);
      live
        // Meaningful transcript events, not cumulative sentence callbacks:
        // interim text is replaceable, and only a finalized, immutable
        // transcript may reach the graph.
        ..onTranscript = (chunk, isFinal) {
          if (!isCurrent()) return;
          if (chunk.isEmpty && !isFinal) return;
          final events = isFinal
              ? _assembler.userFinal(chunk)
              : _assembler.userChunk(chunk);
          for (final event in events) {
            if (event is InterimTranscript) _setTranscript(event.text);
            _dispatchTurn(event);
          }
        }
        ..onAgentTranscript = (chunk, isFinal) {
          if (!isCurrent()) return;
          final events = isFinal
              ? _assembler.assistantFinal(chunk)
              : _assembler.assistantChunk(chunk);
          for (final event in events) {
            _dispatchTurn(event);
          }
        }
        ..onAudio = (pcm) {
          if (!isCurrent()) return;
          if (!_muted) _player?.feed(pcm);
          _markAgentSpeaking();
        }
        ..onInterrupted = () {
          if (!isCurrent()) return;
          // Gemini supplies audio and transcription without a trustworthy
          // word-level alignment. Queuing PCM therefore cannot prove any text
          // was physically heard. The null boundary safely skips durable
          // extraction for this interrupted assistant turn, while the emitted
          // FlushPlayback effect discards the queued audio.
          for (final event in _assembler.interrupted(null)) {
            _dispatchTurn(event);
          }
        }
        ..onTurnComplete = () {
          if (!isCurrent()) return;
          _memoryCallsThisTurn = 0;
          _lastMemoryQuery = null;
          for (final event in _assembler.turnComplete()) {
            _dispatchTurn(event);
          }
          _clearAgentSpeaking();
        }
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
        ..onSetupComplete = () {
          if (!isCurrent()) return;
          // A live Gemini socket and an active turn-processing session are two
          // separate states. Establish the turn-machine identity before the UI
          // advertises the session as live so transcripts can be finalized,
          // extracted, and committed against the loaded notebook revision.
          _dispatchTurn(SessionStarted(
            sessionId: conversationSessionId,
            notebookId: notebookId,
            revision: _revision,
          ));
          _setStatus(SessionStatus.live);
        }
        ..onError = (error) {
          if (!isCurrent()) return;
          jlog('Gemini Live error: $error');
          _setStatus(SessionStatus.error);
        };
      _live = live;

      await live.connect();
      if (!isCurrent()) {
        await live.close();
        return const NotebookTransitionResult.failure(
          'Session start was superseded by another notebook transition.',
        );
      }

      final capture = PcmCapture();
      _capture = capture;
      final mic = MicController(
        capture,
        (pcm) {
          if (isCurrent()) live.sendAudio(pcm);
        },
        reactivate: _activateAudioSession,
      );
      _mic = mic;
      if (!isCurrent()) {
        await capture.stop();
        return const NotebookTransitionResult.failure(
          'Session start was superseded by another notebook transition.',
        );
      }
      await mic.start();
      if (!isCurrent()) {
        await mic.stop();
        return const NotebookTransitionResult.failure(
          'Session start was superseded by another notebook transition.',
        );
      }
      vlog('session', 'mic capture started');
      await _watchAudioSession(isCurrent);

      // Agent-audio playback comes LAST: it's optional (the session still
      // captures voice and builds the graph without it), and its init can
      // stall for minutes on the simulator (just_audio / AVFoundation -11800)
      // and block other audio plugin calls — so it must never sit in front of
      // the mic on the critical path. Timeout-capped and non-fatal.
      final player = PcmPlayer();
      _player = player;
      try {
        await player.init().timeout(const Duration(seconds: 5));
        if (!isCurrent()) {
          await player.dispose();
          return const NotebookTransitionResult.failure(
            'Session start was superseded by another notebook transition.',
          );
        }
        vlog('playback', 'agent-audio playback ready');
      } catch (error) {
        jlog('agent-audio playback unavailable, continuing '
            'without it: $error');
        unawaited(player.dispose().catchError((_) {}));
        if (identical(_player, player)) _player = null;
      }
      if (!isCurrent()) {
        return const NotebookTransitionResult.failure(
          'Session start was superseded by another notebook transition.',
        );
      }
      return const NotebookTransitionResult.success();
    } catch (error, stack) {
      jlog('startSession failed: $error\n$stack');
      await _closeLiveTransportUnlocked();
      _setStatus(SessionStatus.error);
      return const NotebookTransitionResult.failure(
        'Could not start the session. Check your connection and try again.',
      );
    }
  }

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

    final capture = _capture;
    final mic = _mic;
    final live = _live;
    final player = _player;
    _capture = null;
    _mic = null;
    _live = null;
    _player = null;
    for (final sub in _audioSessionSubs) {
      await sub.cancel();
    }
    _audioSessionSubs.clear();

    try {
      await (mic != null ? mic.stop() : capture?.stop());
    } catch (error, stack) {
      vlog('session', 'mic shutdown failed: $error');
      vlogStack(stack);
    }
    try {
      await live?.close();
    } catch (error, stack) {
      vlog('session', 'live transport shutdown failed: $error');
      vlogStack(stack);
    }
    try {
      await player?.dispose();
    } catch (error, stack) {
      vlog('playback', 'player shutdown failed: $error');
      vlogStack(stack);
    }
    if (_audioSessionActive) {
      _audioSessionActive = false;
      try {
        final session = await AudioSession.instance;
        await session.setActive(false).timeout(const Duration(seconds: 2));
      } catch (error) {
        vlog('session', 'audio session release failed: $error');
      }
    }
    _assembler.reset();
  }

  Future<void> _activateAudioSession() async {
    final session = await AudioSession.instance;
    await session.setActive(true);
    _audioSessionActive = true;
  }

  /// Phone calls, Siri and alarms interrupt the session; headphones and
  /// Bluetooth devices move the route. Each maps to a [MicAction] so capture
  /// pauses and resumes cleanly instead of wedging on a dead input.
  Future<void> _watchAudioSession(bool Function() isCurrent) async {
    final AudioSession session;
    try {
      session = await AudioSession.instance;
    } catch (error) {
      vlog('session', 'audio session events unavailable: $error');
      return;
    }
    if (!isCurrent()) return;
    _audioSessionSubs.addAll([
      session.interruptionEventStream.listen((event) {
        if (!isCurrent()) return;
        final action = micActionForInterruption(event);
        vlog('session',
            'interruption ${event.begin ? 'began' : 'ended'} → ${action.name}');
        // Drop queued agent audio so the reply does not resume mid-sentence.
        if (action == MicAction.suspend) unawaited(_player?.flush());
        unawaited(_mic?.apply(action));
      }),
      session.becomingNoisyEventStream.listen((_) {
        if (!isCurrent()) return;
        vlog('session', 'audio route became noisy (headphones unplugged)');
        // Stop the reply rather than switch it to the loudspeaker, and rebind
        // the mic to the built-in input.
        unawaited(_player?.flush());
        unawaited(_mic?.apply(MicAction.restart));
      }),
      session.devicesChangedEventStream.listen((event) {
        if (!isCurrent()) return;
        final action = micActionForDevicesChanged(event);
        if (action != MicAction.none) vlog('session', 'input route changed');
        unawaited(_mic?.apply(action));
      }),
    ]);
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
          vlogStack(stack);
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

final turnJournalServiceProvider = Provider<TurnJournalService>((ref) {
  return TurnJournalService();
});

final micPermissionServiceProvider = Provider<MicPermissionService>((ref) {
  return const MicPermissionService();
});

final journalProvider = NotifierProvider<JournalNotifier, JournalState>(
  JournalNotifier.new,
);
