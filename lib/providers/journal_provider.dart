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
import '../logic/voice_log.dart';
import '../models/journal_state.dart';
import '../services/extract_graph_service.dart';
import '../services/gemini_live_client.dart';
import '../services/retrieve_memory_service.dart';
import 'supabase_provider.dart';

enum SessionStatus { idle, connecting, live, ending, error }

class JournalNotifier extends Notifier<JournalState> {
  GeminiLiveClient? _live;
  PcmCapture? _capture;
  PcmPlayer? _player;
  Timer? _sentenceIdleTimer;
  Timer? _saveDebounce;
  String _turnAccumulator = '';
  String _agentTurnAccumulator = '';
  String _lastTranscript = '';
  final _conversation = <({String role, String text})>[];
  String? _activeNotebookId;
  SessionStatus _status = SessionStatus.idle;
  int _extractGeneration = 0;
  DateTime? _sessionStartedAt;
  String? _lastMemoryQuery;
  int _memoryCallsThisTurn = 0;
  static const _maxMemoryCallsPerTurn = 3;
  bool _muted = false;
  bool _agentSpeaking = false;
  Timer? _agentSpeakingTimer;
  static const _agentSpeakingIdleMs = 400;

  SessionStatus get status => _status;
  String get lastTranscript => _lastTranscript;
  List<({String role, String text})> get conversation =>
      List.unmodifiable(_conversation);
  bool get muted => _muted;
  bool get agentSpeaking => _agentSpeaking;

  @override
  JournalState build() {
    ref.onDispose(() {
      _sentenceIdleTimer?.cancel();
      _saveDebounce?.cancel();
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

  void _onTranscriptChunk(String chunk, bool isFinal) {
    if (chunk.isEmpty) return;
    _turnAccumulator += chunk;
    final trimmed = _turnAccumulator.trim();
    _setTranscript(trimmed);

    if (RegExp(r'[.!?]\s*$').hasMatch(trimmed) &&
        trimmed.length >= sentenceMinChars) {
      _sentenceIdleTimer?.cancel();
      unawaited(_processGraphUpdate(trimmed));
      _turnAccumulator = '';
      return;
    }

    _sentenceIdleTimer?.cancel();
    if (trimmed.length >= sentenceMinChars) {
      _sentenceIdleTimer = Timer(
        const Duration(milliseconds: sentenceIdleMs),
        () {
          final text = _turnAccumulator.trim();
          if (text.length >= sentenceMinChars) {
            _turnAccumulator = '';
            unawaited(_processGraphUpdate(text));
          }
        },
      );
    }

    if (isFinal) {
      _sentenceIdleTimer?.cancel();
      if (trimmed.length >= sentenceMinChars) {
        unawaited(_processGraphUpdate(trimmed));
        _conversation.add((role: 'user', text: trimmed));
        if (_conversation.length > 16) {
          _conversation.removeRange(0, _conversation.length - 16);
        }
        _notifyUi();
      }
      _turnAccumulator = '';
    }
  }

  // Accumulates Lumen's (the agent's) transcribed speech and, on turn end,
  // commits it to the conversation log as an 'agent' turn — rendered as a
  // left/grey bubble in the split transcript panel.
  void _onAgentTranscriptChunk(String chunk, bool isFinal) {
    if (chunk.isNotEmpty) {
      _agentTurnAccumulator += chunk;
    }

    if (isFinal) {
      final trimmed = _agentTurnAccumulator.trim();
      if (trimmed.isNotEmpty) {
        vlog('session', 'agent turn committed (${trimmed.length} chars)');
        _conversation.add((role: 'agent', text: trimmed));
        if (_conversation.length > 16) {
          _conversation.removeRange(0, _conversation.length - 16);
        }
        _notifyUi();
      }
      _agentTurnAccumulator = '';
    }
  }

  Future<void> _processGraphUpdate(String text) async {
    final generation = ++_extractGeneration;
    final extractService = ExtractGraphService(apiKey: Env.geminiApiKey);
    final patch = await extractService.extract(
      text: text,
      state: state,
      mode: 'granular',
      recentConversation: _conversation,
    );
    if (generation != _extractGeneration) return;

    final result = merge_logic.merge(state, text, patch);
    state = result.next;
    vlog('session', 'extract merged: ${state.entities.length} entities, '
        '${state.relations.length} relations');
    _saveStateDebounced();
  }

  void _saveStateDebounced() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () {
      final notebookId = _activeNotebookId;
      if (notebookId == null) return;
      final service = ref.read(supabaseServiceProvider);
      unawaited(service.saveState(notebookId, state));
    });
  }

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

  Future<Map<String, dynamic>> _retrieveMemory(Map<String, dynamic> args) async {
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
    final service = ref.read(supabaseServiceProvider);
    state = await service.loadState(notebookId);
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
        state = await service.loadState(_activeNotebookId!);
      }
      vlog('session', 'notebook=$_activeNotebookId '
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

      final live = GeminiLiveClient(
        apiKey: Env.geminiApiKey,
        // Must match the working web client's Live model (same v1beta
        // BidiGenerateContent endpoint); the old 2.5 preview string is stale.
        model: 'gemini-3.1-flash-live-preview',
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
        ..onTranscript = _onTranscriptChunk
        ..onAgentTranscript = _onAgentTranscriptChunk
        ..onAudio = (pcm) {
          if (!_muted) _player?.feed(pcm);
          _markAgentSpeaking();
        }
        ..onTurnComplete = () {
          _memoryCallsThisTurn = 0;
          _lastMemoryQuery = null;
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
    _sentenceIdleTimer?.cancel();
    _saveDebounce?.cancel();
    _clearAgentSpeaking();
    await _capture?.stop();
    await _live?.close();
    await _player?.dispose();
    if (_activeNotebookId != null) {
      final service = ref.read(supabaseServiceProvider);
      await service.saveState(_activeNotebookId!, state);
      await service.endNotebook(_activeNotebookId!);
    }
    _muted = false;
    _setStatus(SessionStatus.idle);
    _live = null;
    _capture = null;
    _player = null;
    _activeNotebookId = null;
    _turnAccumulator = '';
    _agentTurnAccumulator = '';
  }
}

final journalProvider = NotifierProvider<JournalNotifier, JournalState>(
  JournalNotifier.new,
);
