import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/gemini_live_client.dart';

void main() {
  GeminiLiveClient makeClient() => GeminiLiveClient(
        sessionToken: 'auth_tokens/temporary token',
        model: 'gemini-live-2.5-flash-preview',
        systemInstruction: 'system',
        voice: 'Aoede',
        tools: const [],
      );

  test('connection URI uses a temporary access token, never an API key', () {
    final uri = makeClient().connectionUri;

    expect(uri.queryParameters['access_token'], 'auth_tokens/temporary token');
    expect(uri.queryParameters.containsKey('key'), isFalse);
    expect(uri.path, endsWith('GenerativeService.BidiGenerateContentConstrained'));
  });

  test('outputTranscription fires onAgentTranscript, not onTranscript', () {
    final client = makeClient();

    final agentCalls = <({String text, bool isFinal})>[];
    final userCalls = <({String text, bool isFinal})>[];
    client.onAgentTranscript =
        (text, isFinal) => agentCalls.add((text: text, isFinal: isFinal));
    client.onTranscript =
        (text, isFinal) => userCalls.add((text: text, isFinal: isFinal));

    client.handleServerMessage(jsonEncode({
      'serverContent': {
        'outputTranscription': {'text': 'How did that make you feel?'},
        'turnComplete': true,
      },
    }));

    expect(agentCalls, hasLength(1));
    expect(agentCalls.single.text, 'How did that make you feel?');
    expect(agentCalls.single.isFinal, isTrue);
    // The agent transcription must not leak into the user channel.
    expect(userCalls, isEmpty);
  });

  test('inputTranscription fires onTranscript (user), not onAgentTranscript',
      () {
    final client = makeClient();

    final agentCalls = <({String text, bool isFinal})>[];
    final userCalls = <({String text, bool isFinal})>[];
    client.onAgentTranscript =
        (text, isFinal) => agentCalls.add((text: text, isFinal: isFinal));
    client.onTranscript =
        (text, isFinal) => userCalls.add((text: text, isFinal: isFinal));

    client.handleServerMessage(jsonEncode({
      'serverContent': {
        'inputTranscription': {'text': 'I had a rough day.'},
        'turnComplete': false,
      },
    }));

    expect(userCalls, hasLength(1));
    expect(userCalls.single.text, 'I had a rough day.');
    expect(userCalls.single.isFinal, isFalse);
    // The user transcription must not leak into the agent channel.
    expect(agentCalls, isEmpty);
  });

  test('an interruption is surfaced, and before turn completion', () {
    final client = makeClient();
    final order = <String>[];
    client.onInterrupted = () => order.add('interrupted');
    client.onTurnComplete = () => order.add('turnComplete');

    client.handleServerMessage(jsonEncode({
      'serverContent': {'interrupted': true, 'turnComplete': true},
    }));

    // Documented Gemini order: an interrupted response goes through
    // `interrupted` to `turnComplete` and never emits generationComplete.
    expect(order, ['interrupted', 'turnComplete']);
  });

  test('a transcription marked finished is final even without turnComplete', () {
    final client = makeClient();
    final calls = <({String text, bool isFinal})>[];
    client.onTranscript = (text, isFinal) => calls.add((text: text, isFinal: isFinal));

    client.handleServerMessage(jsonEncode({
      'serverContent': {
        'inputTranscription': {'text': 'I work at '},
      },
    }));
    client.handleServerMessage(jsonEncode({
      'serverContent': {
        'inputTranscription': {'text': 'Acme.', 'finished': true},
      },
    }));

    expect(calls.map((c) => c.isFinal), [false, true]);
  });

  group('agent audio sample rate', () {
    ({List<int> pcm, int rate})? received;
    GeminiLiveClient withAudio() {
      received = null;
      return makeClient()
        ..onAudio = (pcm, rate) => received = (pcm: pcm, rate: rate);
    }

    String audioMessage(String? mimeType) => jsonEncode({
          'serverContent': {
            'modelTurn': {
              'parts': [
                {
                  'inlineData': {
                    'data': base64.encode([1, 2, 3, 4]),
                    if (mimeType != null) 'mimeType': mimeType,
                  },
                },
              ],
            },
          },
        });

    test('reads the rate from the chunk mime type', () {
      withAudio().handleServerMessage(audioMessage('audio/pcm;rate=24000'));
      expect(received?.rate, 24000);
      expect(received?.pcm, [1, 2, 3, 4]);
    });

    test('an unusual declared rate is passed through', () {
      withAudio().handleServerMessage(audioMessage('audio/pcm;rate=16000'));
      expect(received?.rate, 16000);
    });

    test('a missing rate means Gemini\'s 24kHz output', () {
      withAudio().handleServerMessage(audioMessage(null));
      expect(received?.rate, 24000);
    });
  });

  group('connection lifecycle signals', () {
    test('goAway reports the time left before Gemini closes the socket', () {
      Duration? timeLeft;
      var calls = 0;
      final client = makeClient()
        ..onGoAway = (left) {
          calls++;
          timeLeft = left;
        };
      client.handleServerMessage(jsonEncode({
        'goAway': {'timeLeft': '12.5s'},
      }));
      expect(calls, 1);
      expect(timeLeft, const Duration(milliseconds: 12500));
    });

    test('goAway without a parseable timeLeft still fires', () {
      var fired = false;
      Duration? timeLeft = Duration.zero;
      final client = makeClient()
        ..onGoAway = (left) {
          fired = true;
          timeLeft = left;
        };
      client.handleServerMessage(jsonEncode({'goAway': <String, dynamic>{}}));
      expect(fired, isTrue);
      expect(timeLeft, isNull);
    });

    test('setupComplete resolves whenSetupComplete', () async {
      final client = makeClient();
      var done = false;
      unawaited(client.whenSetupComplete.then((_) => done = true));
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);

      client.handleServerMessage(jsonEncode({'setupComplete': {}}));
      await Future<void>.delayed(Duration.zero);
      expect(done, isTrue);
    });
  });
}
