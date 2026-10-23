import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../audio/pcm_player.dart' show geminiOutputSampleRate;
import '../logic/voice_log.dart';

typedef OnTranscript = void Function(String text, bool isFinal);
/// One chunk of agent PCM16 plus the rate it was produced at (from the
/// chunk's `audio/pcm;rate=N` mime type; Gemini's 24kHz when absent).
typedef OnAudio = void Function(Uint8List pcm16, int sampleRate);
typedef OnToolCall = Future<Map<String, dynamic>> Function(
  String toolName,
  Map<String, dynamic> args,
);
typedef OnTurnComplete = void Function();

/// One earlier turn sent as context when a conversation continues.
typedef HistoryTurn = ({bool fromUser, String text});

/// Opens the socket; tests substitute a fake.
typedef LiveChannelFactory = WebSocketChannel Function(Uri uri);

class GeminiLiveClient {
  /// The Gemini token the next [connect] uses. A reconnect may swap in a
  /// fresh one once the old token can no longer start a connection.
  String sessionToken;
  final String model;
  final String systemInstruction;
  final String voice;
  final List<Map<String, dynamic>> tools;

  /// Silence that ends the user's turn (Gemini recommends 500–800 ms).
  final Duration silenceToEndTurn;

  /// Gemini waits for an answer to every tool call before it continues, so a
  /// handler that hangs (a stalled network call) would silence Lumen for
  /// good. Past this, the call is answered with an empty result.
  final Duration toolTimeout;
  final LiveChannelFactory _channelFactory;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  // Protocol state. Gemini Live rejects realtime input sent before the server
  // acks setup, so [sendAudio] buffers frames until [_setupComplete] (and
  // while input is held — see [holdInput]). [_closing] marks a
  // client-initiated close so [connect]'s onDone doesn't report it.
  bool _setupComplete = false;
  bool _closing = false;
  bool _inputHeld = false;
  final List<Uint8List> _pendingAudio = [];
  int _pendingBytes = 0;
  int _framesDropped = 0;
  String? _resumptionHandle;

  /// Pre-setup audio kept at most (16 kHz PCM16 mono: 32 000 B/s → 15 s).
  static const maxPendingAudioBytes = 32000 * 15;
  int _framesSent = 0;
  int _audioChunksIn = 0;

  OnTranscript? onTranscript;
  OnTranscript? onAgentTranscript;
  OnAudio? onAudio;
  OnToolCall? onToolCall;
  OnTurnComplete? onTurnComplete;

  /// The user started speaking over the agent. Any agent audio still queued
  /// for playback was never heard and must not be treated as spoken.
  /// Gemini's documented sequence is `interrupted` then `turnComplete`; an
  /// interrupted response never emits `generationComplete`.
  void Function()? onInterrupted;

  /// Generation finished normally (as opposed to being cut off).
  void Function()? onGenerationComplete;
  void Function()? onSetupComplete;
  void Function(Object)? onError;

  /// Gemini will close this connection soon (its connections are
  /// time-limited). [timeLeft] is null when the server gave no parseable
  /// duration. A warm standby replaces itself on this signal.
  void Function(Duration? timeLeft)? onGoAway;

  Completer<void> _setupDone = _newSetupCompleter();

  static Completer<void> _newSetupCompleter() {
    final completer = Completer<void>();
    // A socket that dies before setup fails this future; nobody may be
    // listening yet, and that must not surface as an unhandled error.
    completer.future.ignore();
    return completer;
  }

  /// The latest handle Gemini issued for resuming this conversation, with
  /// its context, on a new connection. Null until the server sends one.
  String? get resumptionHandle => _resumptionHandle;

  /// Audio waiting for setup (or for [releaseInput]), in bytes.
  int get pendingAudioBytes => _pendingBytes;

  /// Completes when the server acknowledges setup — the point from which the
  /// session accepts content. Reset by each [connect].
  Future<void> get whenSetupComplete => _setupDone.future;

  GeminiLiveClient({
    required this.sessionToken,
    required this.model,
    required this.systemInstruction,
    required this.voice,
    required this.tools,
    this.silenceToEndTurn = const Duration(milliseconds: 700),
    this.toolTimeout = const Duration(seconds: 4),
    String? resumptionHandle,
    LiveChannelFactory? channelFactory,
  })  : _resumptionHandle = resumptionHandle,
        _channelFactory = channelFactory ?? WebSocketChannel.connect;

  @visibleForTesting
  Uri get connectionUri => Uri.parse(
        'wss://generativelanguage.googleapis.com/ws/'
        'google.ai.generativelanguage.v1beta.GenerativeService.'
        'BidiGenerateContentConstrained',
      ).replace(queryParameters: {'access_token': sessionToken});

  /// Opens a connection and sends setup. With a [resumptionHandle] the
  /// server restores the earlier conversation, context included.
  Future<void> connect() async {
    final uri = connectionUri;
    _setupComplete = false;
    _closing = false;
    if (_setupDone.isCompleted) _setupDone = _newSetupCompleter();
    vlog(
        'client',
        'connecting (model=$model'
            '${_resumptionHandle == null ? '' : ', resuming'})…');
    final channel = _channelFactory(uri);
    _channel = channel;

    // Await the actual WebSocket handshake (the web client awaits `open` the
    // same way); otherwise a failed handshake surfaces later as silence.
    try {
      await channel.ready.timeout(const Duration(seconds: 8));
    } catch (error) {
      vlog('client', 'connect FAILED: $error');
      onError?.call(error);
      rethrow;
    }
    vlog('client', 'socket open — sending setup');

    _sub = channel.stream.listen(
      _onMessage,
      onError: (Object error) {
        vlog('client', 'socket error: $error');
        _failSetup(error);
        onError?.call(error);
      },
      // A server-initiated close was previously invisible (no onDone handler):
      // the session died silently and the dock sat "listening" forever.
      onDone: () {
        final code = channel.closeCode;
        final reason = channel.closeReason;
        vlog('client',
            'socket closed (code=$code reason="$reason" byUs=$_closing)');
        if (!_closing) {
          final error =
              StateError('Gemini Live closed the connection ($code $reason)');
          _failSetup(error);
          onError?.call(error);
        }
      },
    );
    _sendSetup();
  }

  void _failSetup(Object error) {
    if (!_setupDone.isCompleted) _setupDone.completeError(error);
  }

  /// Replaces the connection with a new one that resumes this conversation
  /// by its [resumptionHandle] — after a goAway, a dropped socket or a long
  /// pause. Callbacks stay wired; audio sent meanwhile is buffered. Pass
  /// [sessionToken] when the current token can no longer start a connection.
  Future<void> reconnect({String? sessionToken}) async {
    if (sessionToken != null) this.sessionToken = sessionToken;
    await _closeChannel();
    await connect();
  }

  void _sendSetup() {
    final setup = {
      'setup': {
        'model': 'models/$model',
        'system_instruction': {
          'parts': [
            {'text': systemInstruction},
          ],
        },
        'generation_config': {
          'response_modalities': ['AUDIO'],
          'speech_config': {
            'voice_config': {
              'prebuilt_voice_config': {'voice_name': voice},
            },
          },
        },
        // Return the agent's spoken words as text (outputTranscription) and
        // explicitly enable the user speech-to-text (inputTranscription) that
        // the message parser already consumes.
        'output_audio_transcription': <String, dynamic>{},
        'input_audio_transcription': <String, dynamic>{},
        'tools': tools,
        // Ask for resumption handles (and resume with the latest one), so a
        // dropped or recycled connection comes back with its context.
        'session_resumption': {
          if (_resumptionHandle != null) 'handle': _resumptionHandle,
        },
        // Without compression, audio sessions end at ~15 minutes.
        'context_window_compression': {
          'sliding_window': <String, dynamic>{},
        },
        'realtime_input_config': {
          'automatic_activity_detection': {
            'silence_duration_ms': silenceToEndTurn.inMilliseconds,
          },
        },
      },
    };
    _channel!.sink.add(jsonEncode(setup));
  }

  void sendAudio(Uint8List pcm16) {
    // Realtime input before the setup ack is a protocol violation the server
    // may answer by closing the socket, so early frames wait (oldest dropped
    // past the cap) and go out in order once input may flow.
    if (!_setupComplete || _inputHeld) {
      _pendingAudio.add(pcm16);
      _pendingBytes += pcm16.length;
      while (_pendingBytes > maxPendingAudioBytes && _pendingAudio.isNotEmpty) {
        _pendingBytes -= _pendingAudio.removeAt(0).length;
        _framesDropped++;
      }
      return;
    }
    _sendAudioNow(pcm16);
  }

  /// Keeps mic audio buffered even after setup, e.g. while earlier turns are
  /// sent as context ahead of it. [releaseInput] sends the buffer in order.
  void holdInput() => _inputHeld = true;

  void releaseInput() {
    _inputHeld = false;
    _flushPendingAudio();
  }

  void _flushPendingAudio() {
    if (!_setupComplete || _inputHeld || _pendingAudio.isEmpty) return;
    vlog('client', 'sending ${_pendingAudio.length} buffered mic frames');
    final frames = List<Uint8List>.of(_pendingAudio);
    _pendingAudio.clear();
    _pendingBytes = 0;
    frames.forEach(_sendAudioNow);
  }

  void _sendAudioNow(Uint8List pcm16) {
    _framesSent++;
    if (_framesSent == 1 || _framesSent % 50 == 0) {
      vlog('client', 'mic → gemini: frame #$_framesSent (${pcm16.length} B)');
    }
    final b64 = base64.encode(pcm16);
    _channel?.sink.add(
      jsonEncode({
        'realtime_input': {
          'audio': {
            'data': b64,
            'mime_type': 'audio/pcm;rate=16000',
          },
        },
      }),
    );
  }

  /// The mic paused: tells Gemini the audio stream ended so it can flush its
  /// voice detection rather than wait on silence that never arrives.
  void sendAudioStreamEnd() {
    if (!_setupComplete) return;
    _pendingAudio.clear();
    _pendingBytes = 0;
    _channel?.sink.add(jsonEncode({
      'realtime_input': {'audio_stream_end': true},
    }));
  }

  /// Earlier turns of this conversation, as context for a new connection.
  /// `turn_complete: false` asks for no reply; [note] follows as the user's.
  void sendHistory(List<HistoryTurn> turns, {String? note}) {
    final content = [
      for (final turn in turns)
        if (turn.text.trim().isNotEmpty)
          {
            'role': turn.fromUser ? 'user' : 'model',
            'parts': [
              {'text': turn.text},
            ],
          },
      if (note != null)
        {
          'role': 'user',
          'parts': [
            {'text': note},
          ],
        },
    ];
    if (content.isEmpty) return;
    vlog('client', 'context → gemini: ${content.length} turns');
    _channel?.sink.add(jsonEncode({
      'client_content': {'turns': content, 'turn_complete': false},
    }));
  }

  void sendText(String text, {bool endOfTurn = true}) {
    _channel?.sink.add(
      jsonEncode({
        'client_content': {
          'turns': [
            {
              'role': 'user',
              'parts': [
                {'text': text},
              ],
            },
          ],
          'turn_complete': endOfTurn,
        },
      }),
    );
  }

  void respondToTool(String callId, Map<String, dynamic> result) {
    _channel?.sink.add(
      jsonEncode({
        'tool_response': {
          'function_responses': [
            {
              'id': callId,
              'response': {'output': result},
            },
          ],
        },
      }),
    );
  }

  /// Test seam: drive the message parser directly with a raw JSON string,
  /// without a live WebSocket.
  @visibleForTesting
  void handleServerMessage(String raw) => _onMessage(raw);

  static final _ratePattern = RegExp(r'rate=(\d+)');
  static final _secondsPattern = RegExp(r'^(\d+(?:\.\d+)?)s$');

  /// Parses a protobuf JSON Duration such as "12.5s".
  static Duration? _parseProtoDuration(String value) {
    final match = _secondsPattern.firstMatch(value.trim());
    final seconds = double.tryParse(match?.group(1) ?? '');
    if (seconds == null) return null;
    return Duration(microseconds: (seconds * 1e6).round());
  }

  static int _sampleRateOf(String? mimeType) {
    final match = mimeType == null ? null : _ratePattern.firstMatch(mimeType);
    return int.tryParse(match?.group(1) ?? '') ?? geminiOutputSampleRate;
  }

  void _onMessage(dynamic raw) {
    // Gemini Live delivers frames as BINARY (Uint8List / List<int>), not text.
    // Casting straight to String threw on every message, so setupComplete never
    // fired and the whole session silently stalled — decode binary first.
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      text = utf8.decode(raw);
    } else {
      return;
    }
    final msg = jsonDecode(text) as Map<String, dynamic>;

    if (msg.containsKey('setupComplete')) {
      _setupComplete = true;
      vlog(
          'client',
          'setupComplete — session live '
              '(${_pendingAudio.length} mic frames buffered, '
              '$_framesDropped dropped)');
      if (!_setupDone.isCompleted) _setupDone.complete();
      onSetupComplete?.call();
      _flushPendingAudio();
      return;
    }

    if (msg.containsKey('sessionResumptionUpdate')) {
      final update = msg['sessionResumptionUpdate'] as Map<String, dynamic>;
      final handle = update['newHandle'];
      if (update['resumable'] == true && handle is String && handle.isNotEmpty) {
        _resumptionHandle = handle;
      }
      return;
    }

    if (msg.containsKey('goAway')) {
      final timeLeft = (msg['goAway'] as Map?)?['timeLeft'];
      final left = timeLeft is String ? _parseProtoDuration(timeLeft) : null;
      vlog('client', 'goAway (timeLeft=$timeLeft)');
      onGoAway?.call(left);
      return;
    }

    if (msg.containsKey('toolCall')) {
      final calls = msg['toolCall']['functionCalls'] as List<dynamic>? ?? [];
      for (final call in calls) {
        final callMap = call as Map<String, dynamic>;
        final name = callMap['name'] as String? ?? '';
        vlog('client', 'toolCall: $name');
        final id = callMap['id'] as String? ?? '';
        final args = (callMap['args'] as Map<String, dynamic>?) ?? {};
        final handler = onToolCall;
        final clock = Stopwatch()..start();
        final Future<Map<String, dynamic>> pending = handler == null
            ? Future.value(const <String, dynamic>{})
            : handler(name, args);
        pending.timeout(toolTimeout).then((result) {
          vlog('client',
              'toolCall $name answered in ${clock.elapsedMilliseconds}ms');
          respondToTool(id, result);
        }).catchError((Object error) {
          vlog(
            'client',
            'toolCall $name '
                '${error is TimeoutException ? 'timed out' : 'failed'} '
                'after ${clock.elapsedMilliseconds}ms — answering empty',
          );
          respondToTool(id, const {});
        });
      }
      return;
    }

    if (msg.containsKey('serverContent')) {
      final content = msg['serverContent'] as Map<String, dynamic>;
      final turnComplete = content['turnComplete'] == true;

      final parts =
          (content['modelTurn']?['parts'] as List<dynamic>?) ?? const [];
      for (final part in parts) {
        final p = part as Map<String, dynamic>;
        // Responses are AUDIO: Lumen's words arrive as outputTranscription.
        // Text parts here are the model's thinking — never the user's
        // speech (they used to be routed to onTranscript) and never shown.
        if (p.containsKey('text')) {
          vlog(
            'client',
            'gemini → model text part dropped'
                '${p['thought'] == true ? ' (thought)' : ''}',
          );
        }
        if (p.containsKey('inlineData')) {
          final data = p['inlineData'] as Map<String, dynamic>;
          // The server's JSON is camelCase (mimeType) — reading 'mime_type'
          // returned null and silently dropped every agent-audio chunk. The
          // web client treats any inlineData.data as audio; mirror that and
          // only skip if a mime type IS present and clearly not audio.
          final mimeType = (data['mimeType'] ?? data['mime_type']) as String?;
          final b64 = data['data'] as String?;
          if (b64 != null &&
              (mimeType == null || mimeType.startsWith('audio/'))) {
            _audioChunksIn++;
            if (_audioChunksIn == 1 || _audioChunksIn % 25 == 0) {
              vlog('client', 'gemini → audio chunk #$_audioChunksIn');
            }
            onAudio?.call(base64.decode(b64), _sampleRateOf(mimeType));
          }
        }
      }

      if (content.containsKey('inputTranscription')) {
        final transcript =
            content['inputTranscription'] as Map<String, dynamic>;
        final text = transcript['text'] as String? ?? '';
        // Prefer the transcription's own `finished` flag. Input transcription
        // is delivered independently of turn completion with no ordering
        // guarantee, so inferring finality from turnComplete alone conflates
        // "this text is authoritative" with "the model stopped talking".
        final finished = transcript['finished'] as bool? ?? turnComplete;
        vlog('client', 'gemini → user transcript (+${text.length} chars)');
        onTranscript?.call(text, finished);
      }

      // The agent's own spoken words, transcribed back to text.
      if (content.containsKey('outputTranscription')) {
        final transcript =
            content['outputTranscription'] as Map<String, dynamic>;
        final text = transcript['text'] as String? ?? '';
        final finished = transcript['finished'] as bool? ?? turnComplete;
        vlog('client', 'gemini → agent transcript (+${text.length} chars)');
        onAgentTranscript?.call(text, finished);
      }

      if (content['generationComplete'] == true) {
        vlog('client', 'gemini → generationComplete');
        onGenerationComplete?.call();
      }

      // Order matters: interrupted always precedes turnComplete, and consumers
      // use the pair to tell a completed answer from a cut-off one.
      if (content['interrupted'] == true) {
        vlog('client', 'gemini → interrupted');
        onInterrupted?.call();
      }

      if (turnComplete) {
        vlog('client', 'gemini → turnComplete');
        onTurnComplete?.call();
      }
    }
  }

  Future<void> close() async {
    vlog(
        'client',
        'closing (sent=$_framesSent frames, '
            'received=$_audioChunksIn audio chunks)');
    _pendingAudio.clear();
    _pendingBytes = 0;
    await _closeChannel();
  }

  Future<void> _closeChannel() async {
    _closing = true;
    _setupComplete = false;
    // Anyone still waiting for this connection's setup stops waiting now.
    _failSetup(StateError('Gemini Live connection closed'));
    final sub = _sub;
    final channel = _channel;
    _sub = null;
    _channel = null;
    await sub?.cancel();
    await channel?.sink.close();
  }
}
