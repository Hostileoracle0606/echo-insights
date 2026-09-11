import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/pcm_capture.dart';
import '../audio/pcm_player.dart';
import '../env.dart';
import '../logic/agenda.dart' as agenda_logic;
import '../logic/conversation_policy.dart';
import '../logic/merge.dart' as merge_logic;
import '../logic/transcript_assembler.dart';
import '../logic/turn_state.dart';
import '../logic/voice_log.dart';
import '../models/graph_patch.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../services/extract_graph_service.dart';
import '../services/gemini_live_client.dart';
import '../services/notebook_commit_service.dart' as commit_service;
import '../services/notebook_runtime_service.dart';
import '../services/retrieve_memory_service.dart';
import 'supabase_provider.dart';

enum SessionStatus { idle, connecting, live, ending, error }

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
  /// Fires when a completed turn never received an authoritative transcript.
  Timer? _finalizationTimer;
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
  /// Characters of agent text whose audio has actually been played.
  int _agentHeardChars = 0;
  bool _agentHeardUnknown = false;
  final _conversation = <({String role, String text})>[];
  String? _activeNotebookId;
  SessionStatus _status = SessionStatus.idle;
  DateTime? _sessionStartedAt;
  String? _lastMemoryQuery;
  int _memoryCallsThisTurn = 0;
  static const _maxMemoryCallsPerTurn = 3;
  bool _muted = false;
  bool _agentSpeaking = false;
  Timer? _agentSpeakingTimer;
  static const _agentSpeakingIdleMs = 400;

  // Optimistic-concurrency counter from the last-known server snapshot.
  // Every commit reads this fresh (at the moment it actually runs, not when
  // it was queued) and a committed response updates it — see
  // _enqueueCommit / _commitApplyTurn.
  int _revision = 0;
  // Serializes writes to the active notebook: chaining onto this future
  // guarantees commits reach the server in submission order with exactly
  // one in flight at a time. Normalized to never reject so one failed
  // commit can't wedge every commit queued after it.
  final Future<void> _commitQueueTail = Future.value();

  SessionStatus get status => _status;
  String get lastTranscript => _lastTranscript;
  List<({String role, String text})> get conversation =>
      List.unmodifiable(_conversation);
  bool get muted => _muted;
  bool get agentSpeaking => _agentSpeaking;
  int get revision => _revision;

  @override
  JournalState build() {
    ref.onDispose(() {
      _finalizationTimer?.cancel();
      _agentSpeakingTimer?.cancel();
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

  /// Feeds one adapter event into the shared turn machine and carries out the
  /// effects it asks for. The rules — one durable turn per finalized
  /// transcript, identity-checked async results, ordered replay after a
  /// conflict, one reused request id per turn — live in lib/logic/turn_state.dart
  /// and are the same rules the web app runs.
  void _dispatchTurn(TurnEvent event) {
    for (final effect in _turnMachine.dispatch(event)) {
      _performEffect(effect);
    }
    final latest = _turnMachine.state;
    _conversation
      ..clear()
      ..addAll(latest.conversation.map((t) => (role: t.role.name, text: t.text)));
    _notifyUi();
  }

  void _performEffect(TurnEffect effect) {
    switch (effect) {
      case StartDurableExtraction():
        unawaited(_runDurableExtraction(effect));
      case StartCommit():
        final turn = _turnMachine.state.pending
            .where((t) => t.turnId == effect.turnId)
            .firstOrNull;
        if (turn != null) unawaited(_runCommit(turn));
      case ScheduleFinalizationDeadline():
        _finalizationTimer?.cancel();
        _finalizationTimer = Timer(
          const Duration(milliseconds: finalizationDeadlineMs),
          () => _dispatchTurn(FinalizationDeadline(
            speaker: effect.speaker,
            turnId: effect.turnId,
          )),
        );
      case ReloadSnapshot():
        unawaited(_reloadSnapshot());
      case FlushPlayback():
        // PcmPlayer has no flush yet, so queued agent audio finishes playing
        // after a barge-in. The heard watermark is snapshotted at the moment
        // of interruption, so the durable transcript stays a PREFIX of what
        // was heard — conservative, never over-inclusive. See the limitation
        // noted in docs/finalized-turn-extraction.md.
        break;
      case CancelExtraction():
        // Cancellation is a resource optimisation only; the machine's identity
        // check is what decides whether a late result may change anything.
        break;
      case PersistTurn():
      case ForgetTurn():
      case StartProvisionalExtraction():
        break;
    }
  }

  Future<void> _runDurableExtraction(StartDurableExtraction effect) async {
    final extractService = ExtractGraphService(apiKey: Env.geminiApiKey);
    try {
      final patch = await extractService.extract(
        text: effect.transcript,
        state: state,
        mode: 'granular',
        recentConversation: _conversation,
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
      _dispatchTurn(DurableExtractionFailed(key: effect.key, message: '$error'));
    }
  }

  Future<void> _runCommit(FinalizedTurn turn) async {
    // Prefer the in-memory typed patch; fall back to the durable checkpoint so
    // a turn restored from the journal commits without re-extracting.
    final stored = turn.extraction;
    final patch = _lastPatches[turn.turnId] ??
        (stored == null ? null : GraphPatch.fromJson(stored));
    if (patch == null) {
      _dispatchTurn(CommitRejected(turnId: turn.turnId, code: 'invalidRequest'));
      return;
    }
    // Re-merge at commit time against whatever state is current. After a
    // conflict this is what rebases the turn onto the fresh snapshot.
    final result = merge_logic.merge(state, turn.transcript, patch);
    state = result.next;
    vlog(
        'session',
        'extract merged: ${state.entities.length} entities, '
            '${state.relations.length} relations');

    final commitService = ref.read(notebookCommitServiceProvider);
    commit_service.CommitOutcome outcome;
    try {
      outcome = await commitService.commitNotebook(
        notebookId: turn.notebookId,
        expectedRevision: turn.baseRevision ?? _revision,
        // Reused verbatim on every attempt for this turn, including retries
        // after an unknown outcome and replays after a conflict.
        requestId: turn.commitRequestId,
        change: result.change,
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
      _reconcileEntryId(result.entryId, outcome.entryId);
      _lastPatches.remove(turn.turnId);
      _dispatchTurn(CommitCommitted(turnId: turn.turnId, revision: outcome.revision));
      return;
    }
    if (outcome is commit_service.CommitConflict) {
      _dispatchTurn(CommitConflict(
        turnId: turn.turnId,
        currentRevision: outcome.currentRevision,
      ));
      return;
    }
    if (outcome is commit_service.CommitRejected) {
      vlog('session', 'commit rejected: ${outcome.code}');
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
  // until the current one resolves. _commitQueueTail survives only so
  // endSession can await whatever commit is still in flight.

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
          .where((turn) => turn.role == 'agent')
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

  /// Load a specific notebook's saved graph for viewing (dashboard → notebook).
  /// Does not start a voice session — the mic continues it. A later
  /// [startSession] reuses this notebook instead of finding the active one.
  Future<void> openNotebook(String notebookId) async {
    _activeNotebookId = notebookId;
    final commitService = ref.read(notebookCommitServiceProvider);
    final snapshot = await commitService.getNotebookSnapshot(notebookId);
    _revision = snapshot?.revision ?? 0;
    state = snapshot?.state ?? JournalState.empty();
  }

  Future<void> startSession() async {
    if (_status == SessionStatus.connecting || _status == SessionStatus.live) {
      return;
    }
    _setStatus(SessionStatus.connecting);
    _sessionStartedAt = DateTime.now();

    try {
      final service = ref.read(supabaseServiceProvider);
      // Continue the notebook the dashboard opened; otherwise fall back to the
      // user's active notebook (creating one if needed).
      if (_activeNotebookId == null) {
        final notebook = await service.ensureActiveNotebook();
        _activeNotebookId = notebook?.id;
      }
      if (_activeNotebookId != null) {
        final commitService = ref.read(notebookCommitServiceProvider);
        final snapshot =
            await commitService.getNotebookSnapshot(_activeNotebookId!);
        _revision = snapshot?.revision ?? 0;
        state = snapshot?.state ?? JournalState.empty();
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
      } catch (error) {
        debugPrint('[journal] audio session config unavailable: $error');
      }

      final notebookId = _activeNotebookId;
      if (notebookId == null) {
        throw StateError('No active notebook is available');
      }
      final liveSession = await ref
          .read(notebookRuntimeServiceProvider)
          .startLiveSession(notebookId);
      if (liveSession is LiveSessionRejected) {
        throw StateError('Live session rejected: ${liveSession.code}');
      }
      final readySession = liveSession as LiveSessionReady;

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
      live
        // Meaningful transcript events, not cumulative sentence callbacks:
        // interim text is replaceable, and only a finalized, immutable
        // transcript may reach the graph.
        ..onTranscript = (chunk, isFinal) {
          if (chunk.isEmpty && !isFinal) return;
          final events =
              isFinal ? _assembler.userFinal(chunk) : _assembler.userChunk(chunk);
          for (final event in events) {
            if (event is InterimTranscript) _setTranscript(event.text);
            _dispatchTurn(event);
          }
        }
        ..onAgentTranscript = (chunk, isFinal) {
          final events = isFinal
              ? _assembler.assistantFinal(chunk)
              : _assembler.assistantChunk(chunk);
          for (final event in events) {
            _dispatchTurn(event);
          }
        }
        ..onAudio = (pcm) {
          if (!_muted) _player?.feed(pcm);
          _markAgentSpeaking();
          // Audio actually queued for playback: everything transcribed so far
          // is now considered heard. Without a player we cannot know.
          if (_player == null) {
            _agentHeardUnknown = true;
          } else {
            _agentHeardChars = _assembler.assistantText.length;
            _dispatchTurn(PlaybackAdvanced(heardChars: _agentHeardChars));
          }
        }
        ..onInterrupted = () {
          // Only words whose audio played may be finalized; an undeterminable
          // boundary skips durable extraction for this turn entirely.
          _dispatchTurn(AssistantInterrupted(
            heardChars: _agentHeardUnknown ? null : _agentHeardChars,
          ));
        }
        ..onTurnComplete = () {
          _memoryCallsThisTurn = 0;
          _lastMemoryQuery = null;
          _agentHeardChars = 0;
          _agentHeardUnknown = false;
          for (final event in _assembler.turnComplete()) {
            _dispatchTurn(event);
          }
          _clearAgentSpeaking();
        }
        ..onToolCall = (name, args) async {
          if (name == 'get_graph_summary') return _buildGraphSummary();
          if (name == 'get_relevant_memory') return _retrieveMemory(args);
          return const {};
        }
        ..onSetupComplete = () {
          _setStatus(SessionStatus.live);
        }
        ..onError = (error) {
          debugPrint('[journal] Gemini Live error: $error');
          _setStatus(SessionStatus.error);
        };
      _live = live;

      await live.connect();

      _capture = PcmCapture();
      if (!await _capture!.hasPermission()) {
        debugPrint('[journal] microphone permission not granted');
        _setStatus(SessionStatus.error);
        return;
      }
      await _capture!.start((pcm) => _live?.sendAudio(pcm));
      vlog('session', 'mic capture started');

      // Agent-audio playback comes LAST: it's optional (the session still
      // captures voice and builds the graph without it), and its init can
      // stall for minutes on the simulator (just_audio / AVFoundation -11800)
      // and block other audio plugin calls — so it must never sit in front of
      // the mic on the critical path. Timeout-capped and non-fatal.
      _player = PcmPlayer();
      try {
        await _player!.init().timeout(const Duration(seconds: 5));
        vlog('playback', 'agent-audio playback ready');
      } catch (error) {
        debugPrint('[journal] agent-audio playback unavailable, continuing '
            'without it: $error');
        unawaited(_player?.dispose().catchError((_) {}));
        _player = null;
      }
    } catch (error, stack) {
      debugPrint('[journal] startSession failed: $error\n$stack');
      _setStatus(SessionStatus.error);
    }
  }

  Future<void> endSession() async {
    if (_status == SessionStatus.idle) return;
    _setStatus(SessionStatus.ending);
    _finalizationTimer?.cancel();
    _clearAgentSpeaking();
    await _capture?.stop();
    await _live?.close();
    await _player?.dispose();
    if (_activeNotebookId != null) {
      // Every turn already committed itself as it happened; just let any
      // still-in-flight commit finish before marking the notebook ended.
      await _commitQueueTail;
      // Durable turns still queued would be lost by ending here; surface it.
      if (_turnMachine.state.pending.isNotEmpty) {
        vlog('session',
            'ending with ${_turnMachine.state.pending.length} unfinished turn(s)');
      }
      final service = ref.read(supabaseServiceProvider);
      await service.endNotebook(_activeNotebookId!);
    }
    _muted = false;
    _setStatus(SessionStatus.idle);
    _live = null;
    _capture = null;
    _player = null;
    _activeNotebookId = null;
    _assembler.reset();
    _dispatchTurn(const SessionEnded());
  }
}

final journalProvider = NotifierProvider<JournalNotifier, JournalState>(
  JournalNotifier.new,
);
