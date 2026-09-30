import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/gemini_live_client.dart';

import 'support/fake_live_socket.dart';

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

  group('tool calls', () {
    // Plain maps (not records): the matcher compares maps deeply, while a
    // record compares the maps inside it by identity.
    List<Map<String, Object?>> toolResponses(FakeLiveSocket socket) => [
          for (final message in socket.sent)
            if (message['tool_response'] != null)
              for (final r in (message['tool_response']
                  as Map)['function_responses'] as List)
                {
                  'id': (r as Map)['id'],
                  'output': (r['response'] as Map)['output'],
                },
        ];

    Map<String, dynamic> toolCall(String id) => {
          'toolCall': {
            'functionCalls': [
              {
                'id': id,
                'name': 'get_relevant_memory',
                'args': {'query': 'Priya'},
              },
            ],
          },
        };

    FakeLiveSocket Function() connectedClient(
      FakeAsync async,
      OnToolCall handler,
    ) {
      FakeLiveSocket? socket;
      final client = GeminiLiveClient(
        sessionToken: 't',
        model: 'm',
        systemInstruction: 's',
        voice: 'Aoede',
        tools: const [],
        toolTimeout: const Duration(seconds: 4),
        channelFactory: (uri) => socket = FakeLiveSocket(uri),
      )..onToolCall = handler;
      client.connect();
      async.flushMicrotasks();
      socket!.serverSends({'setupComplete': <String, dynamic>{}});
      async.flushMicrotasks();
      return () => socket!;
    }

    test('a tool that never answers is answered empty at the timeout', () {
      fakeAsync((async) {
        final socket = connectedClient(
          async,
          (name, args) => Completer<Map<String, dynamic>>().future,
        );
        socket().serverSends(toolCall('call-1'));
        async.elapse(const Duration(seconds: 3));
        expect(toolResponses(socket()), isEmpty, reason: 'still in time');

        async.elapse(const Duration(seconds: 1));
        expect(toolResponses(socket()), [
          {'id': 'call-1', 'output': <String, dynamic>{}},
        ]);
      });
    });

    test('a tool that answers in time is answered with its result, once', () {
      fakeAsync((async) {
        final socket = connectedClient(async, (name, args) async {
          await Future<void>.delayed(const Duration(seconds: 1));
          return {'context': 'Priya climbs'};
        });
        socket().serverSends(toolCall('call-2'));
        async.elapse(const Duration(seconds: 10));
        expect(toolResponses(socket()), [
          {
            'id': 'call-2',
            'output': {'context': 'Priya climbs'},
          },
        ]);
      });
    });

    test('a tool that throws is answered empty straight away', () {
      fakeAsync((async) {
        final socket = connectedClient(
          async,
          (name, args) async => throw StateError('network'),
        );
        socket().serverSends(toolCall('call-3'));
        async.flushMicrotasks();
        expect(toolResponses(socket()), [
          {'id': 'call-3', 'output': <String, dynamic>{}},
        ]);
      });
    });
  });
}
