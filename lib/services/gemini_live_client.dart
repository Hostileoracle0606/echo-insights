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

class GeminiLiveClient {
  final String sessionToken;
  final String model;
  final String systemInstruction;
  final String voice;
  final List<Map<String, dynamic>> tools;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  // Protocol state. Gemini Live rejects realtime input sent before the server
  // acks setup — [sendAudio] drops frames until [_setupComplete]. [_closing]
  // marks a client-initiated close so [connect]'s onDone doesn't report it.
  bool _setupComplete = false;
  bool _closing = false;
  int _framesDropped = 0;
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

  GeminiLiveClient({
    required this.sessionToken,
    required this.model,
    required this.systemInstruction,
    required this.voice,
    required this.tools,
  });

  @visibleForTesting
  Uri get connectionUri => Uri.parse(
        'wss://generativelanguage.googleapis.com/ws/'
        'google.ai.generativelanguage.v1beta.GenerativeService.'
        'BidiGenerateContentConstrained',
      ).replace(queryParameters: {'access_token': sessionToken});

  Future<void> connect() async {
    final uri = connectionUri;
    _setupComplete = false;
    _closing = false;
    vlog('client', 'connecting (model=$model)…');
    _channel = WebSocketChannel.connect(uri);

    // Await the actual WebSocket handshake (the web client awaits `open` the
    // same way); otherwise a failed handshake surfaces later as silence.
    try {
      await _channel!.ready.timeout(const Duration(seconds: 8));
    } catch (error) {
      vlog('client', 'connect FAILED: $error');
      onError?.call(error);
      rethrow;
    }
    vlog('client', 'socket open — sending setup');

    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (Object error) {
        vlog('client', 'socket error: $error');
        onError?.call(error);
      },
      // A server-initiated close was previously invisible (no onDone handler):
      // the session died silently and the dock sat "listening" forever.
      onDone: () {
        final code = _channel?.closeCode;
        final reason = _channel?.closeReason;
        vlog('client',
            'socket closed (code=$code reason="$reason" byUs=$_closing)');
        if (!_closing) {
          onError?.call(
              StateError('Gemini Live closed the connection ($code $reason)'));
        }
      },
    );
    _sendSetup();
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
      },
    };
    _channel!.sink.add(jsonEncode(setup));
  }

  void sendAudio(Uint8List pcm16) {
    // Realtime input before the setup ack is a protocol violation the server
    // may answer by closing the socket — drop (and count) early frames.
    if (!_setupComplete) {
      _framesDropped++;
      if (_framesDropped == 1 || _framesDropped % 25 == 0) {
        vlog(
            'client',
            'dropping mic frame before setupComplete '
                '(dropped=$_framesDropped)');
      }
      return;
    }
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
              '(dropped $_framesDropped early mic frames)');
      onSetupComplete?.call();
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
        if (handler == null) {
          respondToTool(id, const {});
        } else {
          handler(name, args)
              .then((result) => respondToTool(id, result))
              .catchError((_) => respondToTool(id, const {}));
        }
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
        if (p.containsKey('text')) {
          onTranscript?.call(p['text'] as String, turnComplete);
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
    _closing = true;
    vlog(
        'client',
        'closing (sent=$_framesSent frames, '
            'received=$_audioChunksIn audio chunks)');
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _setupComplete = false;
  }
}
