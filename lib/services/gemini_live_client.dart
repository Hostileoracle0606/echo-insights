import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

typedef OnTranscript = void Function(String text, bool isFinal);
typedef OnAudio = void Function(Uint8List pcm16);
typedef OnToolCall = Future<Map<String, dynamic>> Function(
  String toolName,
  Map<String, dynamic> args,
);
typedef OnTurnComplete = void Function();

class GeminiLiveClient {
  final String apiKey;
  final String model;
  final String systemInstruction;
  final String voice;
  final List<Map<String, dynamic>> tools;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;

  OnTranscript? onTranscript;
  OnTranscript? onAgentTranscript;
  OnAudio? onAudio;
  OnToolCall? onToolCall;
  OnTurnComplete? onTurnComplete;
  void Function()? onSetupComplete;
  void Function(Object)? onError;

  GeminiLiveClient({
    required this.apiKey,
    required this.model,
    required this.systemInstruction,
    required this.voice,
    required this.tools,
  });

  Future<void> connect() async {
    final uri = Uri.parse(
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=$apiKey',
    );
    _channel = WebSocketChannel.connect(uri);
    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (Object error) => onError?.call(error),
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
      onSetupComplete?.call();
      return;
    }

    if (msg.containsKey('toolCall')) {
      final calls = msg['toolCall']['functionCalls'] as List<dynamic>? ?? [];
      for (final call in calls) {
        final callMap = call as Map<String, dynamic>;
        final name = callMap['name'] as String? ?? '';
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
          final mimeType = data['mime_type'] as String? ?? '';
          if (mimeType.startsWith('audio/')) {
            final bytes = base64.decode(data['data'] as String);
            onAudio?.call(bytes);
          }
        }
      }

      if (content.containsKey('inputTranscription')) {
        final transcript =
            content['inputTranscription'] as Map<String, dynamic>;
        onTranscript?.call(transcript['text'] as String? ?? '', turnComplete);
      }

      // The agent's own spoken words, transcribed back to text.
      if (content.containsKey('outputTranscription')) {
        final transcript =
            content['outputTranscription'] as Map<String, dynamic>;
        onAgentTranscript?.call(
          transcript['text'] as String? ?? '',
          turnComplete,
        );
      }

      if (turnComplete) onTurnComplete?.call();
    }
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _channel?.sink.close();
    _channel = null;
  }
}
