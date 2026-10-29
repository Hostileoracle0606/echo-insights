import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_output.dart';
import '../audio/pcm_capture.dart';
import '../audio/pcm_player.dart';
import '../audio/standard_opening.dart';
import '../audio/voice_engine.dart';
import '../logic/agenda.dart' as agenda_logic;
import '../logic/conversation_policy.dart';
import '../logic/echo_gate.dart';
import '../logic/live_session_guard.dart';
import '../logic/live_signal_gate.dart';
import '../logic/opening_choice.dart';
import '../logic/resume_context.dart';
import '../logic/memory_removal.dart';
import '../logic/merge.dart' as merge_logic;
import '../logic/session_opening_coordinator.dart';
import '../logic/transcript_assembler.dart';
import '../logic/turn_effect_queue.dart';
import '../logic/turn_state.dart';
import '../logic/voice_log.dart';
import '../models/graph_patch.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/recall_activity.dart';
import '../models/session_brief.dart';
import '../models/session_card.dart';
import '../models/upsert_activity.dart';
import '../services/gemini_live_client.dart';
import '../services/memory_control_service.dart';
import '../services/notebook_commit_service.dart' as commit_service;
import '../services/notebook_runtime_service.dart';
import '../services/retrieve_memory_service.dart';
import '../services/session_brief_service.dart';
import '../services/session_card_service.dart';
import '../services/turn_journal_service.dart';
import 'opening_prep_provider.dart';
import 'supabase_provider.dart';
import 'voice_services_provider.dart';

enum SessionStatus { idle, connecting, live, paused, ending, error }

/// Lumen joining a new notebook as it opens (plan: Flow 2). The page waits
/// behind a loader while [joining]; [failed] offers Retry or opening
/// without voice.
enum JoiningPhase { none, joining, failed }

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

/// How long "Removed Priya · Undo" holds a removal before it is sent (LM-29).
const Duration removeUndoWindow = Duration(seconds: 5);

/// How a [JournalNotifier.removeEntity] call ended.
enum RemovalOutcome { removed, undone, failed }

class JournalNotifier extends Notifier<JournalState> {
  GeminiLiveClient? _live;
  MicCapture? _capture;
  // The app-level player (AudioOutput), attached while a session uses it.
  PcmPlayer? _player;
  VoidCallback? _speakingListener;
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

  // The notebook's saved conversation from earlier sessions (server-side),
  // shown before this run's turns and used as context when continuing.
  final _history = <ConversationTurn>[];
  // Turns already saved (or loaded) for the active notebook.
  final Set<String> _savedTurnIds = {};
  DateTime? _saveRetryAfter;

  JoiningPhase _joining = JoiningPhase.none;
  Timer? _joiningTimer;
  JoiningPhase get joining => _joining;

  String? _activeNotebookId;
  SessionStatus _status = SessionStatus.idle;
  DateTime? _sessionStartedAt;
  String? _lastMemoryQuery;
  int _memoryCallsThisTurn = 0;
  static const _maxMemoryCallsPerTurn = 3;
  // What the last memory lookup brought back (LM-13 / LM-14 read it).
  RecallActivity? _recall;
  int _recallSeq = 0;
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
  // until its greeting has been heard. Null outside a session.
  SessionOpeningCoordinator? _opening;

  // The opening chosen once per new-session start: the clip that plays and
  // the up-front context both follow this one choice. [_openingBrief] is the
  // sign-in brief as it stood at the choice (sent to Gemini even when it
  // did not play). All null when continuing a notebook.
  OpeningChoice? _openingChoice;
  SessionBrief? _openingBrief;
  StandardOpening? _openingClip;

  // The bundled clips (intro, fallback), each loaded once; and the
  // display-only transcript rows of greetings played in this notebook.
  // Greetings never reach the turn machine: there is nothing to extract.
  final _bundledOpenings = <OpeningChoice, Future<StandardOpening?>>{};
  final _greetingRows = <ConversationTurn>[];

  // Optimistic-concurrency counter from the last-known server snapshot.
  // Every commit reads this fresh (at the moment it actually runs, not when
  // it was queued) and a committed response updates it — see
  // _enqueueCommit / _commitApplyTurn.
  int _revision = 0;

  // LM-29: ids the user removed from memory (from the snapshot, plus any
  // removal still inside its undo window). merge() never adds them back.
  final Set<String> _suppressed = {};
  final Map<String, _PendingRemoval> _pendingRemovals = {};
  BackgroundFlush? _backgroundFlush;
  Set<String> get suppressedEntityIds => Set.unmodifiable(_suppressed);

  SessionStatus get status => _status;
  String get lastTranscript => _lastTranscript;
  String get liveUserText => _liveUserText;
  String get liveAgentText => _liveAgentText;

  /// The chat pane's rows: finalized turns plus unfinished utterances, in the
  /// order they were spoken. An utterance keeps its slot from first word to
  /// finalization, so nothing vanishes or jumps while Gemini's finals lag.
  List<TranscriptRow> get transcriptRows {
    final current = {for (final turn in _conversation) turn.turnId};
    final rows = <TranscriptRow>[
      for (final turn in _history)
        if (!current.contains(turn.turnId)) (turn: turn, pending: false),
      for (final turn in _greetingRows) (turn: turn, pending: false),
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
  RecallActivity? get recall => _recall;
  List<ConversationTurn> get conversation => List.unmodifiable(_conversation);
  List<ConversationTurn> get inProgress => List.unmodifiable(_inProgress);
  bool get muted => _muted;
  bool get agentSpeaking => _agentSpeaking;

  /// The user's turn is over and Lumen hasn't started answering: from a
  /// typed send, or [speechEndGraceProvider] after the last of their speech,
  /// until Lumen's first word or sound (or a turn it chose to leave silent).
  bool get awaitingReply => _awaitingReply;
  bool _awaitingReply = false;
  Timer? _speechEndTimer;

  void _setAwaitingReply(bool awaiting) {
    if (!awaiting) {
      _speechEndTimer?.cancel();
      _speechEndTimer = null;
    }
    if (_awaitingReply == awaiting) return;
    _awaitingReply = awaiting;
    _notifyUi();
  }

  /// More of the user's speech arrived: not waiting yet, but if nothing
  /// follows for the grace period (just past Gemini's own end-of-speech
  /// silence), their turn is over.
  void _userStillSpeaking() {
    _setAwaitingReply(false);
    _speechEndTimer = Timer(ref.read(speechEndGraceProvider), () {
      _speechEndTimer = null;
      if (_status == SessionStatus.live && !_agentSpeaking) {
        _setAwaitingReply(true);
      }
    });
  }

  /// Lumen owns the floor: the session is starting and its opening has not
  /// finished playing yet. The dock shows Lumen, never "You", meanwhile —
  /// user audio is not accepted until this clears.
  bool get openingInProgress {
    final opening = _opening;
    // Continuing a conversation, the user has the floor from the tap (the
    // mic records while Lumen connects).
    if (_status == SessionStatus.connecting) {
      return !(opening?.acceptsUserAudio ?? false);
    }
    return opening?.inProgress ?? false;
  }
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
      _joiningTimer?.cancel();
      // A removal the user did not undo is never dropped: send what is left.
      for (final entry in _pendingRemovals.entries) {
        entry.value.timer.cancel();
        unawaited(entry.value.service.removeEntity(entry.key));
      }
      _pendingRemovals.clear();
      _syncBackgroundFlush();
      _session?.gate.dispose();
      unawaited(_capture?.stop());
      unawaited(_live?.close());
      final player = _player;
      _detachPlayer();
      if (player != null) unawaited(_releasePlayer(player));
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
    _echoGate.lumenAudible(speaking, at: DateTime.now());
    if (speaking) _setAwaitingReply(false);
    if (!speaking) {
      if (_agentTurnDone) {
        _agentTurnDone = false;
        _liveAgentText = '';
      }
      if (_opening?.markOpeningHeard() ?? false) {
        vlog('session', 'greeting heard — user turn enabled');
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
    _saveNewTurns(latest.notebookId);
    _inProgress
      ..clear()
      ..addAll(_turnMachine.inProgress);
    _extracting = latest.pending.isNotEmpty;
    _notifyUi();
  }

  /// Saves each newly finalized turn (both speakers) to the notebook's
  /// server-side transcript, once. A failed save is retried on a later
  /// change, at most every 30 s.
  void _saveNewTurns(String? notebookId) {
    if (notebookId == null || notebookId != _activeNotebookId) return;
    final retryAfter = _saveRetryAfter;
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;
    for (final turn in _conversation) {
      if (!_savedTurnIds.add(turn.turnId)) continue;
      unawaited(_saveTurn(notebookId, turn));
    }
  }

  Future<void> _saveTurn(String notebookId, ConversationTurn turn) async {
    try {
      await ref.read(transcriptStoreProvider).save(notebookId, turn);
    } catch (error) {
      vlog('session', 'transcript save failed, will retry: $error');
      if (notebookId == _activeNotebookId) {
        _savedTurnIds.remove(turn.turnId);
        _saveRetryAfter = DateTime.now().add(const Duration(seconds: 30));
      }
    }
  }

  /// Earlier turns first, then this run's (without the ones already saved).
  List<ConversationTurn> get _earlierConversation {
    final saved = {for (final turn in _history) turn.turnId};
    return [
      ..._history,
      for (final turn in _conversation)
        if (!saved.contains(turn.turnId)) turn,
    ];
  }

  bool get _continuesConversation => continuesConversation(
        conversation: _earlierConversation,
        entries: state.entries,
      );

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
        _recall = null;
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
        final turn = _turnMachine.state.pending
            .where((t) => t.turnId == effect.key.turnId)
            .firstOrNull;
        if (!extractAssistantTurns && turn?.speaker == Speaker.assistant) {
          vlog('timing', 'extract assistant turn skipped');
          final patch = GraphPatch.empty();
          _lastPatches[effect.key.turnId] = patch;
          _dispatchTurn(DurableExtractionSucceeded(
            key: effect.key,
            payload: patch.toJson(),
          ));
          return;
        }
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
    final clock = Stopwatch()..start();
    try {
      final retrieval =
          await ref.read(retrieveMemoryServiceProvider).retrieveResult(
        query: effect.transcript,
        notebookId: effect.key.notebookId,
        state: state,
      );
      vlog('timing', 'extract retrieve +${clock.elapsedMilliseconds}ms');
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
      vlog('timing', 'extract model +${clock.elapsedMilliseconds}ms');
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
        final result = merge_logic.merge(state, turn.transcript, patch,
            suppressed: _suppressed);
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
      final commitClock = Stopwatch()..start();
      outcome = await commitService.commitNotebook(
        notebookId: turn.notebookId,
        expectedRevision: prepared.expectedRevision,
        requestId: turn.commitRequestId,
        change: prepared.change,
      );
      vlog('timing', 'commit +${commitClock.elapsedMilliseconds}ms');
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
          state = _adoptSnapshot(snapshot);
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
      state = _adoptSnapshot(snapshot);
      // Pending turns now replay over the fresh snapshot in their original
      // order, keeping the request ids they were minted with.
      _dispatchTurn(SnapshotReloaded(revision: snapshot.revision));
    } catch (error) {
      vlog('session', 'snapshot reload failed: $error');
    }
  }

  // ── LM-29: edit and remove what Lumen keeps ─────────────────────────────

  /// The server's view, with any removal still inside its undo window kept
  /// hidden (the server has not been told yet, so it still has the entity).
  JournalState _adoptSnapshot(commit_service.NotebookSnapshot snapshot) {
    _suppressed
      ..clear()
      ..addAll(snapshot.suppressedEntityIds)
      ..addAll(_pendingRemovals.keys);
    var next = snapshot.state;
    for (final id in _pendingRemovals.keys) {
      next = withoutEntity(next, id);
    }
    return next;
  }

  /// Writes the user's own description for [entityId] in every notebook.
  /// Applied here first; a failed call reloads the server snapshot and
  /// rethrows so the caller can say so.
  Future<void> editEntityDescription(String entityId, String text) async {
    var trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > 800) trimmed = trimmed.substring(0, 800);
    final entity = state.entities[entityId];
    if (entity != null) {
      state = state.copyWith(entities: {
        ...state.entities,
        entityId:
            entity.copyWith(description: trimmed, descriptionSource: 'user'),
      });
    }
    try {
      await ref
          .read(memoryControlServiceProvider)
          .editDescription(entityId, trimmed);
    } catch (error) {
      vlog('session', 'edit description failed: $error');
      await _reloadSnapshot();
      rethrow;
    }
  }

  /// Hides [entityId] now and removes it from memory once [removeUndoWindow]
  /// passes without [undoRemove] — or at once if the app goes to the
  /// background, so a removal is never left unsent. Completes when it was
  /// sent, undone, or failed (a failure brings the entity back).
  Future<RemovalOutcome> removeEntity(String entityId) {
    final existing = _pendingRemovals[entityId];
    if (existing != null) return existing.done.future;

    final before = state;
    final pending = _PendingRemoval(
      hidden: HiddenEntity.capture(before, entityId),
      service: ref.read(memoryControlServiceProvider),
      timer: Timer(removeUndoWindow, () => unawaited(_sendRemoval(entityId))),
    );
    _pendingRemovals[entityId] = pending;
    _suppressed.add(entityId);
    state = withoutEntity(before, entityId);
    _syncBackgroundFlush();
    return pending.done.future;
  }

  /// Cancels a removal still inside its undo window. False once it was sent.
  bool undoRemove(String entityId) {
    final pending = _pendingRemovals.remove(entityId);
    if (pending == null) return false;
    pending.timer.cancel();
    _syncBackgroundFlush();
    _suppressed.remove(entityId);

    state = pending.hidden
        .restoreInto(state, (id) => _pendingRemovals[id]?.hidden);
    pending.done.complete(RemovalOutcome.undone);
    return true;
  }

  /// Sends every removal still inside its undo window, now.
  Future<void> flushPendingRemovals() => Future.wait([
        for (final id in _pendingRemovals.keys.toList()) _sendRemoval(id),
      ]);

  Future<void> _sendRemoval(String entityId) async {
    final pending = _pendingRemovals.remove(entityId);
    if (pending == null) return;
    pending.timer.cancel();
    _syncBackgroundFlush();
    try {
      await pending.service.removeEntity(entityId);
      pending.done.complete(RemovalOutcome.removed);
    } catch (error) {
      // Not removed on the server, so not suppressed there either: show the
      // entity again rather than pretend it is gone.
      vlog('session', 'remove entity failed: $error');
      _suppressed.remove(entityId);
      await _reloadSnapshot();
      pending.done.complete(RemovalOutcome.failed);
    }
  }

  void _syncBackgroundFlush() {
    final hook = _backgroundFlush;
    if (_pendingRemovals.isEmpty) {
      if (hook != null) WidgetsBinding.instance.removeObserver(hook);
      _backgroundFlush = null;
    } else if (hook == null) {
      final added = BackgroundFlush(() => unawaited(flushPendingRemovals()));
      WidgetsBinding.instance.addObserver(added);
      _backgroundFlush = added;
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
      Map<String, dynamic> args, bool Function() isCurrent) async {
    final notebookId = _activeNotebookId;
    final query = (args['query'] as String?)?.trim() ?? '';
    // Over-call guardrails: tiny query, identical repeat (within turn), per-turn cap.
    if (notebookId == null ||
        query.length < 2 ||
        query == _lastMemoryQuery ||
        _memoryCallsThisTurn >= _maxMemoryCallsPerTurn) {
      return memoryToolResult(MemoryRetrieval.empty);
    }
    _memoryCallsThisTurn++;
    _lastMemoryQuery = query;
    final service = ref.read(retrieveMemoryServiceProvider);
    // User scope: every conversation the user has had, not just this one.
    final retrieval = await service.retrieveResult(
      query: query,
      notebookId: notebookId,
      scope: RetrievalScope.user,
    );
    if (retrieval.entityIds.isNotEmpty && isCurrent()) {
      _recall = RecallActivity(
        seq: ++_recallSeq,
        entityIds: retrieval.entityIds,
        quotes: retrieval.quotes,
        at: DateTime.now(),
      );
      _notifyUi();
    }
    return memoryToolResult(retrieval);
  }

  Future<void> _loadNotebookUnlocked(String notebookId) async {
    final clock = Stopwatch()..start();
    final commitService = ref.read(notebookCommitServiceProvider);
    // The snapshot and the saved conversation are independent reads, so they
    // share one round trip's wait. _loadHistory never throws.
    final history = _loadHistory(notebookId);
    final snapshot = await commitService.getNotebookSnapshot(notebookId);
    vlog('timing', 'open: snapshot +${clock.elapsedMilliseconds}ms');
    _activeNotebookId = notebookId;
    _greetingRows.clear();
    _history
      ..clear()
      ..addAll(await history);
    vlog('timing', 'open: saved turns +${clock.elapsedMilliseconds}ms');
    _savedTurnIds
      ..clear()
      ..addAll(_history.map((turn) => turn.turnId));
    _saveRetryAfter = null;
    _revision = snapshot?.revision ?? 0;
    state = snapshot == null ? JournalState.empty() : _adoptSnapshot(snapshot);
    await _restoreTurnsForNotebook(notebookId);
    vlog('timing', 'open: turn journal +${clock.elapsedMilliseconds}ms');
  }

  /// The saved conversation, or none if it can't be read right now (the
  /// notebook still opens; a session then starts without that context).
  Future<List<ConversationTurn>> _loadHistory(String notebookId) async {
    try {
      final turns = await ref
          .read(transcriptStoreProvider)
          .load(notebookId)
          .timeout(const Duration(seconds: 5));
      vlog('session', 'loaded ${turns.length} saved turns');
      return turns;
    } catch (error) {
      vlog('session', 'saved transcript unavailable: $error');
      return const [];
    }
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

      final opening = _activeNotebookId != notebookId;
      if (opening) {
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

      // A new notebook opens with Lumen (greeting and all); one with an
      // earlier conversation opens quietly on its graph and transcript.
      if ((opening || autoStart) && !_continuesConversation) {
        return _openWithLumenUnlocked();
      }
      return const NotebookTransitionResult.success();
    });
  }

  /// Starts the session as the page opens: the greeting plays while the
  /// socket connects, with nothing covering the page. After
  /// [openingTimeoutProvider] without going live, the attempt is dropped and
  /// the page offers Retry or opening without voice.
  Future<NotebookTransitionResult> _openWithLumenUnlocked() async {
    _setJoining(JoiningPhase.joining);
    _joiningTimer?.cancel();
    _joiningTimer = Timer(ref.read(openingTimeoutProvider), () {
      _joiningTimer = null;
      if (_joining != JoiningPhase.joining) return;
      vlog('session', 'Lumen did not join in time');
      _setJoining(JoiningPhase.failed);
      unawaited(endSession());
    });
    final result = await _startSessionUnlocked();
    _joiningTimer?.cancel();
    _joiningTimer = null;
    if (_joining == JoiningPhase.joining) {
      _setJoining(_status == SessionStatus.live
          ? JoiningPhase.none
          : JoiningPhase.failed);
    }
    return result;
  }

  void _setJoining(JoiningPhase phase) {
    if (_joining == phase) return;
    _joining = phase;
    _notifyUi();
  }

  /// Retry from the join-failed banner.
  Future<NotebookTransitionResult> retryJoining() {
    final intent = ++_lifecycleIntent;
    _setJoining(JoiningPhase.joining);
    if (_status == SessionStatus.idle || _status == SessionStatus.error) {
      _setStatus(SessionStatus.connecting);
    }
    return _serializeLifecycle(() {
      if (intent != _lifecycleIntent) {
        return Future.value(const NotebookTransitionResult.failure(
          'Session start was superseded by a newer request.',
        ));
      }
      if (_status == SessionStatus.error) _setStatus(SessionStatus.idle);
      return _openWithLumenUnlocked();
    });
  }

  /// "Open without voice" from the join-failed banner: the notebook stays
  /// open, and the mic starts a session whenever the user wants one.
  Future<void> openWithoutVoice() async {
    _joiningTimer?.cancel();
    _joiningTimer = null;
    _setJoining(JoiningPhase.none);
    if (_status != SessionStatus.idle) await endSession();
  }

  /// Backwards-compatible safe entry point for callers that only load.
  Future<NotebookTransitionResult> openNotebook(String notebookId) =>
      enterNotebook(notebookId);

  Future<NotebookTransitionResult> startSession() {
    final intent = ++_lifecycleIntent;
    // Instant feedback: the dock shows "Lumen · Connecting" on the tap
    // itself, even while another lifecycle step finishes ahead of this
    // request in the serialized queue.
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

  // ─── Session lifecycle (plan: Flow 3) ─────────────────────────────────────
  //
  //   IDLE ─tap→ CONNECTING (the mic records from the tap) ─→ LIVE
  //   LIVE ─tap→ PAUSED (mic closed, stream end sent, socket kept) ─tap→ LIVE
  //   LIVE/PAUSED ─End→ ENDING → IDLE; the notebook stays open, resumable.
  //
  // A goAway or dropped socket reconnects by resumption handle without
  // changing state ([reconnecting] shows it). Nothing here creates a
  // notebook: sessions run only in the notebook the user opened.

  /// The mic pauses: capture stops and Gemini is told the stream ended, but
  /// the connection (and its context) stays for an instant resume.
  Future<void> pauseMic() => _serializeLifecycle(() async {
        if (_status != SessionStatus.live) return;
        _setStatus(SessionStatus.paused);
        _live?.sendAudioStreamEnd();
        try {
          await _capture?.stop();
        } catch (error) {
          vlog('session', 'mic pause failed: $error');
        }
        vlog('session', 'mic paused');
      });

  /// The mic resumes on the same connection, reconnecting by handle first
  /// if the connection lapsed while paused.
  Future<NotebookTransitionResult> resumeMic() => _serializeLifecycle(() async {
        if (_status != SessionStatus.paused) {
          return const NotebookTransitionResult.success();
        }
        final session = _session;
        final capture = _capture;
        if (session == null ||
            capture == null ||
            !_isCurrentLiveSession(session.binding, session.live)) {
          // Nothing to resume: start afresh (context is seeded again).
          await _closeLiveTransportUnlocked();
          return _startSessionUnlocked();
        }
        _setStatus(SessionStatus.live);
        try {
          await capture.start((pcm) => _onMicFrame(session.binding, pcm));
        } catch (error) {
          vlog('session', 'mic resume failed: $error');
          _setStatus(SessionStatus.paused);
          return const NotebookTransitionResult.failure(
            'The microphone could not restart. Try again.',
          );
        }
        vlog('session', 'mic resumed');
        if (_connectionLapsed) unawaited(_reconnect(session, 'resumed'));
        return const NotebookTransitionResult.success();
      });

  /// Sends a turn typed in the composer, live or with the mic paused. It is
  /// recorded at once as its own finalized user turn — saved, extracted and
  /// committed like a spoken one — and sent to Gemini so Lumen answers it.
  /// Typing while Lumen speaks interrupts it, as speaking over it does.
  /// While the connection is being restored the text waits, in order, and
  /// goes out once it is back. False when there is nothing to send or no
  /// live session to send it to.
  bool sendTypedTurn(String text) {
    final typed = text.trim();
    final session = _session;
    final live = _live;
    if (typed.isEmpty ||
        session == null ||
        live == null ||
        !_isCurrentLiveSession(session.binding, live) ||
        (_status != SessionStatus.live && _status != SessionStatus.paused)) {
      return false;
    }
    final reply = _turnMachine.state.activeAssistant;
    if (reply != null && !reply.interrupted) {
      // The machine cuts the reply at the heard prefix and flushes playback;
      // the assembler and the speaker drop the reply's late chunks.
      _assembler.typedTurnInterrupted();
      _droppingCutOffReply = true;
      _liveAgentText = '';
      _agentTurnDone = false;
    } else if (_agentSpeaking) {
      // Gemini already completed the reply; only its audio is still queued.
      unawaited(_flushPlayback());
    }
    _setAwaitingReply(true);
    _dispatchTurn(TypedTurnSubmitted(
      text: typed,
      submittedAt: DateTime.now().toUtc().toIso8601String(),
    ));
    if (_reconnecting || _connectionLapsed) {
      _typedTurnsAwaitingConnection.add(typed);
      if (!_reconnecting) {
        unawaited(_reconnect(session, 'typed turn', whilePaused: true));
      }
      return true;
    }
    live.sendText(typed);
    return true;
  }

  /// Ends the voice session. The notebook stays open, and the next tap
  /// continues its conversation.
  Future<NotebookTransitionResult> endSession() {
    final intent = ++_lifecycleIntent;
    _liveSessionGuard.invalidate();
    _abortConnecting();
    return _serializeLifecycle(() async {
      if (intent != _lifecycleIntent) {
        return const NotebookTransitionResult.failure(
          'Session end was superseded by a newer request.',
        );
      }
      if (_status == SessionStatus.idle) {
        return const NotebookTransitionResult.success();
      }
      if (_joining == JoiningPhase.joining) _setJoining(JoiningPhase.none);
      _setStatus(SessionStatus.ending);
      await _closeLiveTransportUnlocked();
      _dispatchTurn(const SessionEnded());
      _setStatus(SessionStatus.idle);
      return const NotebookTransitionResult.success();
    });
  }

  /// A superseded start may still be waiting for its setup ack (up to 8 s),
  /// holding the lifecycle queue. Closing the half-open connection ends
  /// that wait at once, so what comes next (End, Retry) isn't kept waiting.
  void _abortConnecting() {
    final live = _live;
    if (live != null && _status == SessionStatus.connecting) {
      unawaited(live.close());
    }
  }

  /// A previous connection lapsed (goAway or drop) while paused; resuming
  /// reconnects first.
  bool _connectionLapsed = false;

  /// A reconnect by resumption handle is in progress.
  bool _reconnecting = false;
  bool get reconnecting => _reconnecting;

  /// The session the user is in (null while idle or connecting).
  _PreparedLive? _session;

  // Typed turns waiting for the connection to come back, in the order sent.
  final List<String> _typedTurnsAwaitingConnection = [];

  // A typed turn cut Lumen off: the reply's audio still in flight is dropped
  // until Gemini completes the cut-off turn (it sends `interrupted`, then
  // `turnComplete`, up to ~0.8 s later).
  bool _droppingCutOffReply = false;

  // Mic audio captured before the socket exists (the credential is still
  // being taken). Handed to the client, which buffers it until it may send.
  final List<Uint8List> _preconnectAudio = [];
  int _preconnectBytes = 0;

  // Mutes the mic while Lumen plays where nothing cancels its echo. Trusts
  // the mic until a session learns otherwise.
  EchoGate _echoGate = EchoGate(echoCancelled: true);

  void _onMicFrame(LiveSessionLease lease, Uint8List frame) {
    if (!_liveSessionGuard.isCurrent(lease)) return;
    if (_status == SessionStatus.paused) return;
    // Lumen's greeting has the floor on a new notebook's first session.
    if (!(_opening?.acceptsUserAudio ?? false)) return;
    final pcm = _echoGate.admit(frame, at: DateTime.now());
    final live = _live;
    if (live != null) {
      live.sendAudio(pcm);
      return;
    }
    _preconnectAudio.add(pcm);
    _preconnectBytes += pcm.length;
    while (_preconnectBytes > GeminiLiveClient.maxPendingAudioBytes) {
      _preconnectBytes -= _preconnectAudio.removeAt(0).length;
    }
  }

  // ─── Session start ────────────────────────────────────────────────────────

  Future<NotebookTransitionResult> _startSessionUnlocked() async {
    if (_status == SessionStatus.live || _status == SessionStatus.paused) {
      return const NotebookTransitionResult.success();
    }
    final notebookId = _activeNotebookId;
    if (notebookId == null) {
      _setStatus(SessionStatus.idle);
      return const NotebookTransitionResult.failure(
        'Open a notebook to start a session.',
      );
    }
    _setStatus(SessionStatus.connecting);
    // A notebook with earlier conversation continues it: no greeting, the
    // earlier turns go to Gemini as context, and the user has the floor
    // from the tap. A new notebook opens with Lumen's greeting.
    final continuing = _continuesConversation;
    final opening = _opening = SessionOpeningCoordinator();
    _openingChoice = null;
    _openingBrief = null;
    _openingClip = null;
    if (continuing) opening.markOpeningHeard();
    final lease = _liveSessionGuard.begin();

    try {
      vlog(
          'session',
          'notebook=$notebookId (${state.entities.length} entities, '
              '${continuing ? 'continuing' : 'new conversation'})');
      final capture = ref.read(micCaptureFactoryProvider)();
      if (!await capture.hasPermission()) {
        debugPrint('[journal] microphone permission not granted');
        _setStatus(SessionStatus.error);
        return const NotebookTransitionResult.failure(
          'Microphone permission is required to start a journal session.',
        );
      }
      if (!_liveSessionGuard.isCurrent(lease)) return _superseded;
      // Record from the tap (the pre-connect buffer): nothing said while
      // Lumen connects is lost.
      _preconnectAudio.clear();
      _preconnectBytes = 0;
      _capture = capture;
      await capture.start((pcm) => _onMicFrame(lease, pcm));
      if (!_liveSessionGuard.isCurrent(lease)) return _superseded;
      final echoCancelled = await ref.read(echoCancellationProvider)();
      _echoGate = EchoGate(echoCancelled: echoCancelled)
        ..lumenAudible(_agentSpeaking, at: DateTime.now());
      vlog(
          'session',
          'mic capture started'
              '${echoCancelled ? '' : ' (no echo cancellation: mic muted while Lumen plays)'}');

      final prepared =
          await _prepareLiveUnlocked(lease, continuing: continuing);
      if (prepared == null) return _superseded;
      return await _activateUnlocked(prepared, continuing: continuing);
    } catch (error, stack) {
      // Superseded (End, Retry, another notebook): whoever superseded it
      // cleans up; this attempt is not an error.
      if (!_liveSessionGuard.isCurrent(lease)) return _superseded;
      debugPrint('[journal] startSession failed: $error\n$stack');
      await _closeLiveTransportUnlocked();
      _setStatus(SessionStatus.error);
      return const NotebookTransitionResult.failure(
        'Could not start the session. Check your connection and try again.',
      );
    }
  }

  static const _superseded = NotebookTransitionResult.failure(
    'Session start was superseded by another notebook transition.',
  );

  /// Everything a session needs besides the mic. Independent steps run in
  /// parallel; the socket needs the credential first. Returns null when a
  /// newer lifecycle request superseded this one.
  Future<_PreparedLive?> _prepareLiveUnlocked(
    LiveSessionLease lease, {
    required bool continuing,
  }) async {
    final clock = Stopwatch()..start();
    void mark(String stage) =>
        vlog('timing', '$stage +${clock.elapsedMilliseconds}ms');

    final notebookId = _activeNotebookId;
    if (notebookId == null) {
      throw StateError('No active notebook is available');
    }

    // Agent-audio playback is optional (the session still captures voice and
    // builds the graph without it). The app-level player was started at
    // sign-in; waiting for it is timeout-capped and runs in parallel, never
    // in front of the socket. The audio session is configured natively by
    // the voice engine, which the mic and the player share.
    final playbackReady = _attachPlayer(ref.read(audioOutputProvider));
    final greetingReady =
        continuing ? Future<StandardOpening?>.value() : _loadOpening();
    if (!continuing) {
      // Greet as soon as the speaker is ready, while the socket is still
      // connecting — the greeting covers the connection time. The mic stays
      // gated until the greeting is heard.
      unawaited(Future.wait([playbackReady, greetingReady]).then((_) {
        if (_liveSessionGuard.isCurrent(lease)) _startGreeting();
      }));
    }
    final liveSession = await _takeCredential(notebookId, mark);
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

    final live = ref.read(liveClientFactoryProvider)(
      sessionToken: readySession.sessionToken,
      model: readySession.model,
    );
    final prepared = _PreparedLive(
      binding: binding,
      notebookId: notebookId,
      conversationSessionId: conversationSessionId,
      live: live,
      gate: LiveSignalGate(),
      tokenExpiresAt: readySession.expiresAt,
    );
    bool isCurrent() => _isCurrentLiveSession(binding, live);
    void signal(LiveSignal value) {
      if (isCurrent()) prepared.gate.receive(value);
    }

    live
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
      ..onToolCall = (name, args) async {
        if (!isCurrent()) return const <String, dynamic>{};
        Map<String, dynamic> result;
        if (name == 'get_relevant_memory') {
          result = await _retrieveMemory(args, isCurrent);
        } else {
          result = const {};
        }
        if (!isCurrent()) return const <String, dynamic>{};
        return result;
      }
      ..onGoAway = (timeLeft) {
        if (!isCurrent() || !identical(_session, prepared)) return;
        vlog('session', 'Gemini will close this connection in $timeLeft');
        unawaited(_reconnect(prepared, 'goAway'));
      }
      ..onError = (error) {
        // Errors while connecting surface through the awaited setup; a
        // reconnect handles its own attempts.
        if (!isCurrent() || !identical(_session, prepared)) return;
        if (_reconnecting) return;
        vlog('session', 'connection lost: $error');
        unawaited(_reconnect(prepared, 'connection lost'));
      };
    _live = live;

    // Continuing: earlier turns go first, then what the user already said.
    if (continuing) live.holdInput();
    for (final pcm in _preconnectAudio) {
      live.sendAudio(pcm);
    }
    _preconnectAudio.clear();
    _preconnectBytes = 0;

    await live.connect();
    await live.whenSetupComplete.timeout(const Duration(seconds: 8));
    if (!isCurrent()) return null;
    mark('setup complete');
    final playbackOk = await playbackReady;
    await greetingReady;
    if (!isCurrent()) return null;
    mark(playbackOk ? 'playback ready' : 'playback unavailable');
    return prepared;
  }

  /// The prepared session becomes the user's live session: the turn machine
  /// learns its identity, signals start flowing, and — when continuing —
  /// the earlier conversation is sent ahead of the buffered mic audio.
  Future<NotebookTransitionResult> _activateUnlocked(
    _PreparedLive prepared, {
    required bool continuing,
  }) async {
    bool isCurrent() => _isCurrentLiveSession(prepared.binding, prepared.live);
    _session = prepared;
    _connectionLapsed = false;
    // Typed turns an earlier connection never sent reach Gemini as context
    // (sendHistory below), not as new turns to answer.
    _typedTurnsAwaitingConnection.clear();
    _droppingCutOffReply = false;
    _sessionStartedAt = DateTime.now();
    // A live Gemini socket and an active turn-processing session are two
    // separate states. Establish the turn-machine identity before anything
    // arrives so transcripts can be finalized, extracted, and committed
    // against the loaded notebook revision.
    _dispatchTurn(SessionStarted(
      sessionId: prepared.conversationSessionId,
      notebookId: prepared.notebookId,
      revision: _revision,
    ));
    _setStatus(SessionStatus.live);
    if (!continuing) _startGreeting();
    prepared.gate.activate((signal) {
      if (isCurrent()) _handleSignal(signal);
    });
    // Gemini plans from the graph summary given up front, ahead of anything
    // the user says, instead of stopping to fetch it with a tool call before
    // each reply (~0.5 s a turn). Continuing, the earlier turns follow it.
    prepared.live.sendHistory(
      continuing
          ? resumeContext(
              conversation: _earlierConversation,
              entries: state.entries,
            )
          : const [],
      note: continuing ? resumeNote : null,
      // A new notebook: the greeting's exact words and its brief lead, so
      // Gemini never greets again or repeats the question.
      context: openingContext(
        openingLine: continuing ? null : _openingClip?.text,
        brief: continuing ? null : _openingBrief,
        briefAlreadyRaised: _openingChoice != OpeningChoice.brief,
        graphSummary: _buildGraphSummary(),
      ),
    );
    if (continuing) prepared.live.releaseInput();
    vlog('timing', 'live');
    return const NotebookTransitionResult.success();
  }

  /// Reconnects [session] by its resumption handle: the same token while it
  /// can still start a connection (within its 30 min life), otherwise a
  /// fresh one. Context stays on Gemini's side, so nothing is re-sent. While
  /// paused, it only marks the connection lapsed; resuming reconnects.
  /// A typed turn reconnects even while paused ([whilePaused]): the
  /// composer keeps the mic off but still needs the connection.
  Future<void> _reconnect(
    _PreparedLive session,
    String reason, {
    bool whilePaused = false,
  }) async {
    bool isCurrent() => _isCurrentLiveSession(session.binding, session.live) &&
        identical(_session, session);
    if (_reconnecting || !isCurrent()) return;
    final live = session.live;
    if (_status == SessionStatus.paused && !whilePaused) {
      vlog('session', 'connection lapsed while paused ($reason)');
      _connectionLapsed = true;
      await live.close();
      return;
    }
    if (live.resumptionHandle == null) {
      debugPrint('[journal] Gemini Live error without a resumption handle: '
          '$reason');
      _setStatus(SessionStatus.error);
      return;
    }
    _reconnecting = true;
    _notifyUi();
    vlog('session', 'reconnecting by handle ($reason)');
    try {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!isCurrent()) return;
        if (attempt > 0) {
          await Future<void>.delayed(Duration(milliseconds: 500 << attempt));
          if (!isCurrent()) return;
        }
        try {
          String? token;
          final tokenUsable = DateTime.now()
              .add(const Duration(minutes: 1))
              .isBefore(session.tokenExpiresAt);
          if (attempt > 0 || !tokenUsable) {
            final outcome =
                await _takeCredential(session.notebookId, (stage) {});
            if (outcome is! LiveSessionReady) {
              throw StateError('no token for reconnect');
            }
            token = outcome.sessionToken;
            session.tokenExpiresAt = outcome.expiresAt;
          }
          if (!isCurrent()) return;
          await live.reconnect(sessionToken: token);
          await live.whenSetupComplete.timeout(const Duration(seconds: 8));
          _connectionLapsed = false;
          vlog('session', 'reconnected (attempt ${attempt + 1})');
          // A cut-off reply's turn ended with the old connection.
          _droppingCutOffReply = false;
          for (final typed in _typedTurnsAwaitingConnection) {
            live.sendText(typed);
          }
          _typedTurnsAwaitingConnection.clear();
          return;
        } catch (error) {
          vlog('session', 'reconnect attempt ${attempt + 1} failed: $error');
        }
      }
      if (isCurrent()) {
        debugPrint('[journal] Gemini Live could not reconnect');
        _setStatus(SessionStatus.error);
      }
    } finally {
      _reconnecting = false;
      _notifyUi();
    }
  }

  /// Plays the chosen opening clip through this session's player, once.
  /// Without a clip or a speaker there is nothing to wait for, so the floor
  /// passes to the user immediately.
  void _startGreeting() {
    final opening = _opening;
    if (opening == null || !opening.claimGreeting()) return;
    final clip = _openingClip;
    final player = _player;
    if (clip == null) {
      if (opening.markOpeningHeard()) vlog('session', 'no greeting clip');
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    _greetingRows.add(ConversationTurn(
      turnId: 'lumen-greeting-$now',
      role: Speaker.assistant,
      text: clip.text,
      createdAt: now,
      startedAt: now,
    ));
    var fed = false;
    if (player != null) {
      // The words ride on the pill while the voice plays and leave when it
      // drains (the completed-turn path in _setAgentSpeaking).
      _liveAgentText = clip.text;
      _agentTurnDone = true;
      for (final chunk in clip.chunks(const Duration(milliseconds: 250))) {
        fed = player.feed(
              chunk,
              sampleRate: clip.sampleRate,
              audible: !_muted,
            ) ||
            fed;
      }
    }
    if (fed) {
      vlog('timing', 'greeting playing (${clip.duration.inMilliseconds}ms)');
      _openingPlayed();
    } else {
      _liveAgentText = '';
      _agentTurnDone = false;
      if (opening.markOpeningHeard()) {
        vlog('session', 'greeting unplayable — user turn enabled');
      }
    }
    _notifyUi();
  }

  /// Chooses this session's opening — synchronously, over whatever the
  /// sign-in load already has (never waiting on it) — and loads its clip.
  /// Only a bundled clip's asset load is awaited; a brief carries its audio.
  Future<StandardOpening?> _loadOpening() {
    final prep = ref.read(openingPrepProvider);
    final state = prep.current;
    final choice = _openingChoice = chooseOpening(
      state: state,
      knownNewAccount: prep.knownNewAccount,
      now: DateTime.now(),
    );
    final brief = _openingBrief = state?.brief;
    vlog('session', 'opening: ${choice.name}');
    final opening = _opening;
    final clip = switch (choice) {
      OpeningChoice.brief => Future<StandardOpening?>.value(StandardOpening(
          text: brief!.openingLine,
          pcm: brief.pcm,
          sampleRate: brief.sampleRate,
        )),
      OpeningChoice.intro => _loadBundled(choice, StandardOpening.load),
      OpeningChoice.fallback =>
        _loadBundled(choice, StandardOpening.loadReturning),
    };
    return clip.then((loaded) {
      // A load that lands after a newer session started is not its clip.
      if (identical(_opening, opening)) _openingClip = loaded;
      return loaded;
    });
  }

  Future<StandardOpening?> _loadBundled(
    OpeningChoice choice,
    Future<StandardOpening> Function(AssetBundle) load,
  ) {
    return _bundledOpenings[choice] ??= load(rootBundle).then(
      (clip) => clip,
      onError: (Object error) {
        debugPrint('[journal] ${choice.name} clip unavailable: $error');
        _bundledOpenings.remove(choice);
        return null;
      },
    );
  }

  /// The chosen clip actually played. The intro plays only in the first
  /// session of a sign-up run; a brief plays once, on every device.
  void _openingPlayed() {
    final prep = ref.read(openingPrepProvider);
    switch (_openingChoice) {
      case OpeningChoice.intro:
        prep.markIntroPlayed();
      case OpeningChoice.brief:
        final brief = _openingBrief!;
        // A refresh may have landed a newer brief since the choice; only
        // the one that played is marked here.
        final current = prep.current?.brief;
        if (current != null &&
            current.createdAt.isAtSameMomentAs(brief.createdAt)) {
          prep.markPlayedLocally();
        }
        unawaited(Future<void>.sync(
          () =>
              ref.read(sessionBriefServiceProvider).markPlayed(brief.createdAt),
        ).then(
          (_) => vlog('session', 'session brief marked played'),
          onError: (Object error) => vlog(
              'session', 'marking the session brief played failed: $error'),
        ));
      case OpeningChoice.fallback:
      case null:
        break;
    }
  }

  /// One Gemini signal, now that the session is the user's.
  void _handleSignal(LiveSignal signal) {
    switch (signal) {
      // Meaningful transcript events, not cumulative sentence callbacks:
      // interim text is replaceable, and only a finalized, immutable
      // transcript may reach the graph.
      case UserTranscript(:final text, :final isFinal):
        if (text.isEmpty && !isFinal) return;
        if (text.trim().isNotEmpty) _userStillSpeaking();
        final events =
            isFinal ? _assembler.userFinal(text) : _assembler.userChunk(text);
        for (final event in events) {
          if (event is InterimTranscript) _setTranscript(event.text);
          _dispatchTurn(event);
        }
      case AgentTranscript(:final text, :final isFinal):
        // A reply cut off by a typed turn still trails words; they don't
        // answer the new turn.
        if (text.trim().isNotEmpty && !_droppingCutOffReply) {
          _setAwaitingReply(false);
        }
        final events = isFinal
            ? _assembler.assistantFinal(text)
            : _assembler.assistantChunk(text);
        for (final event in events) {
          _dispatchTurn(event);
        }
      case AgentAudio(:final pcm, :final sampleRate):
        if (_droppingCutOffReply) return;
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
        // Lumen may end a turn without speaking; that ends the wait too,
        // unless it is the cut-off reply's own completion.
        if (!_droppingCutOffReply) _setAwaitingReply(false);
        _droppingCutOffReply = false;
        _memoryCallsThisTurn = 0;
        _lastMemoryQuery = null;
        for (final event in _assembler.turnComplete()) {
          _dispatchTurn(event);
        }
        // With a playback clock, Lumen stops "speaking" when its queued
        // audio drains — usually seconds after Gemini's turn completes.
        if (_player == null) _clearAgentSpeaking();
    }
  }

  /// The user's held token (fetched at sign-in), or — when none can be had,
  /// e.g. the user-scoped route isn't deployed yet — one from the notebook's
  /// own route.
  Future<LiveSessionOutcome> _takeCredential(
    String notebookId,
    void Function(String stage) mark,
  ) async {
    final held = await ref.read(liveCredentialsProvider).take();
    if (held != null) {
      mark('credential (held)');
      return held;
    }
    final outcome = await ref
        .read(notebookRuntimeServiceProvider)
        .startLiveSession(notebookId);
    mark('credential (notebook route)');
    return outcome;
  }

  /// Attaches the app-level player and wires its playback clock to the dock.
  /// False when playback is unavailable (the session continues without it).
  Future<bool> _attachPlayer(AudioOutput output) async {
    final player = await output.whenReady();
    if (player == null || player.isDisposed) {
      debugPrint('[journal] agent-audio playback unavailable, continuing '
          'without it');
      return false;
    }
    if (identical(_player, player)) return true;
    _detachPlayer();
    void listener() {
      if (identical(_player, player)) {
        _setAgentSpeaking(player.speaking.value);
      }
    }

    player.speaking.addListener(listener);
    _player = player;
    _speakingListener = listener;
    vlog('playback', 'agent-audio playback attached');
    return true;
  }

  void _detachPlayer() {
    final player = _player;
    final listener = _speakingListener;
    _player = null;
    _speakingListener = null;
    if (player != null && listener != null && !player.isDisposed) {
      player.speaking.removeListener(listener);
    }
  }

  /// Silences what this session queued; the player itself belongs to the
  /// app and stays up for the next session. Never waits long: a stalled
  /// backend must not hold up a session ending.
  Future<void> _releasePlayer(PcmPlayer player) async {
    try {
      await player.flush().timeout(const Duration(seconds: 2));
    } catch (error) {
      vlog('playback', 'player flush incomplete: $error');
    }
  }

  static const liveTools = [
    {
      'function_declarations': [
        {
          'name': 'get_relevant_memory',
          'description':
              'Retrieve past memory relevant to a query: related entities and how they connect. Use when the user references something from earlier, or when grounding your reply in prior context would help. Distinct from the graph summary given at the start. For planning only — never read aloud.',
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
    _setAwaitingReply(false);
    for (final timer in _finalizationTimers.values) {
      timer.cancel();
    }
    _finalizationTimers.clear();
    _clearAgentSpeaking();
    _clearLiveText();
    _opening = null;
    _session?.gate.dispose();
    _session = null;
    _connectionLapsed = false;
    _typedTurnsAwaitingConnection.clear();
    _droppingCutOffReply = false;
    _preconnectAudio.clear();
    _preconnectBytes = 0;

    final capture = _capture;
    final live = _live;
    final player = _player;
    _capture = null;
    _live = null;
    _detachPlayer();

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
    if (player != null) await _releasePlayer(player);
    _assembler.reset();
  }

  /// Stops realtime input, drains notebook-scoped writes, and then releases
  /// the active notebook identity. Callers may navigate only after success.
  Future<NotebookTransitionResult> leaveNotebook() {
    // The operation itself is serialized, but stale realtime callbacks must be
    // rejected immediately while it waits for an in-progress start operation.
    final intent = ++_lifecycleIntent;
    _liveSessionGuard.invalidate();
    _abortConnecting();
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

  Future<NotebookTransitionResult> _leaveNotebookUnlocked() async {
    final notebookId = _activeNotebookId;
    final shouldEndNotebook = _sessionStartedAt != null;
    if (notebookId == null && _status == SessionStatus.idle) {
      return const NotebookTransitionResult.success();
    }

    _setStatus(SessionStatus.ending);
    await _closeLiveTransportUnlocked();
    _dispatchTurn(const SessionEnded());

    // Set only once the notebook is really over (ended_at saved).
    String? closedNotebookId;
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
        closedNotebookId = notebookId;
      }
    }

    _muted = false;
    _sessionStartedAt = null;
    _activeNotebookId = null;
    _restoredNotebookId = null;
    _history.clear();
    _savedTurnIds.clear();
    _joiningTimer?.cancel();
    _joiningTimer = null;
    _joining = JoiningPhase.none;
    _lastTranscript = '';
    _lastMemoryQuery = null;
    _memoryCallsThisTurn = 0;
    _setStatus(SessionStatus.idle);
    if (closedNotebookId != null) _writeSessionCard(closedNotebookId);
    return const NotebookTransitionResult.success();
  }

  /// Asks the runtime for the notebook's closing card (LM-15) without
  /// waiting for it: leaving is already done and never fails because of the
  /// card. A card that isn't written now is written the next time the
  /// notebook is left, or when the closing screen (LM-16) retries.
  void _writeSessionCard(String notebookId) {
    // The next session's brief is written from this notebook, in parallel
    // with the card; it never blocks or fails leaving. Once written, the
    // opening state reloads so the next new notebook can play it.
    final prep = ref.read(openingPrepProvider);
    final briefs = ref.read(sessionBriefServiceProvider);
    unawaited(Future<void>.sync(() => briefs.requestBrief(notebookId)).then(
      (_) {
        vlog('session', 'session brief ready for $notebookId');
        return prep.refresh();
      },
      onError: (Object error) => vlog(
        'session',
        'session brief failed for $notebookId: ${error.runtimeType}'
            '${error is SessionBriefException ? ' ${error.statusCode}' : ''}',
      ),
    ));
    unawaited(
      Future<SessionCard?>.sync(
        () => ref.read(sessionCardServiceProvider).close(notebookId),
      ).then(
        (card) => vlog(
          'session',
          'session card ${card == null ? 'skipped' : 'ready'} for $notebookId',
        ),
        onError: (Object error) => vlog(
          'session',
          'session card failed for $notebookId: ${error.runtimeType}'
              '${error is SessionCardException ? ' ${error.statusCode} ${error.code}' : ''}',
        ),
      ),
    );
  }
}

/// A connected, set-up Gemini session. Its [gate] passes signals through
/// once the session is activated.
/// A removal inside its undo window.
class _PendingRemoval {
  _PendingRemoval({
    required this.hidden,
    required this.service,
    required this.timer,
  });

  final HiddenEntity hidden;
  final MemoryControlService service;
  final Timer timer;
  final Completer<RemovalOutcome> done = Completer<RemovalOutcome>();
}

class _PreparedLive {
  _PreparedLive({
    required this.binding,
    required this.notebookId,
    required this.conversationSessionId,
    required this.live,
    required this.gate,
    required this.tokenExpiresAt,
  });

  final LiveSessionLease binding;
  final String notebookId;
  final String conversationSessionId;
  final GeminiLiveClient live;
  final LiveSignalGate gate;

  /// When [live]'s token stops working; a reconnect after that takes a
  /// fresh one.
  DateTime tokenExpiresAt;
}

/// How long a new notebook waits for Lumen to join before offering Retry.
final openingTimeoutProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 10),
);

/// Makes the session's microphone; tests substitute a fake.
final micCaptureFactoryProvider = Provider<MicCapture Function()>(
  (ref) => EngineMicCapture.new,
);

/// How long after the last of the user's speech their turn counts as over
/// for the "mulling it over" cue: just past Gemini's 700 ms end-of-speech
/// silence. Tests shorten it.
final speechEndGraceProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 900),
);

/// Whether the platform removes Lumen's voice from the mic. Where it can't
/// say (no voice engine, as in tests), the mic is trusted as before.
final echoCancellationProvider = Provider<Future<bool> Function()>(
  (ref) => () async {
    try {
      return await VoiceEngine.instance.echoCancellation();
    } catch (_) {
      return true;
    }
  },
);

/// Makes the session's Gemini Live client; tests substitute a fake socket.
final liveClientFactoryProvider = Provider<
    GeminiLiveClient Function({
      required String sessionToken,
      required String model,
    })>(
  (ref) => ({required String sessionToken, required String model}) =>
      GeminiLiveClient(
        sessionToken: sessionToken,
        model: model,
        systemInstruction: geminiLiveSystemInstruction,
        voice: 'Aoede',
        tools: JournalNotifier.liveTools,
      ),
);

/// One chat-pane row: a conversation turn, and whether it is still unfinished.
typedef TranscriptRow = ({ConversationTurn turn, bool pending});

final turnJournalServiceProvider = Provider<TurnJournalService>((ref) {
  return TurnJournalService();
});

final journalProvider = NotifierProvider<JournalNotifier, JournalState>(
  JournalNotifier.new,
);
