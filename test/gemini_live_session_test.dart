import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/gemini_live_client.dart';
import 'support/fake_live_socket.dart';

void main() {
  late List<FakeLiveSocket> sockets;

  GeminiLiveClient makeClient({String? handle}) {
    sockets = [];
    return GeminiLiveClient(
      sessionToken: 'auth_tokens/one',
      model: 'gemini-3.1-flash-live-preview',
      systemInstruction: 'system',
      voice: 'Aoede',
      tools: const [],
      resumptionHandle: handle,
      channelFactory: (uri) {
        final socket = FakeLiveSocket(uri);
        sockets.add(socket);
        return socket;
      },
    );
  }

  Uint8List frame(int n) => Uint8List.fromList([n, n]);

  List<int> sentBytes(FakeLiveSocket socket) => [
        for (final message in socket.audioFrames)
          ...base64.decode(
            ((message['realtime_input'] as Map)['audio'] as Map)['data']
                as String,
          ),
      ];

  test('setup asks for resumption, compression and ~700 ms turn detection',
      () async {
    final client = makeClient();
    await client.connect();

    final setup = sockets.single.setup;
    expect(setup['session_resumption'], isEmpty);
    expect(setup['context_window_compression'], {
      'sliding_window': <String, dynamic>{},
    });
    expect(setup['realtime_input_config'], {
      'automatic_activity_detection': {'silence_duration_ms': 700},
    });
    // The constrained token locks model and modality; setup keeps its own
    // instructions, voice and transcription.
    expect(setup['model'], 'models/gemini-3.1-flash-live-preview');
    expect(setup['system_instruction'], isNotNull);
    expect(setup['input_audio_transcription'], isNotNull);
  });

  test('audio sent before setup is buffered and flushed in order', () async {
    final client = makeClient();
    client.sendAudio(frame(1));
    await client.connect();
    client.sendAudio(frame(2));
    expect(sockets.single.audioFrames, isEmpty);

    sockets.single.serverSends({'setupComplete': <String, dynamic>{}});
    await pumpEventQueue();
    client.sendAudio(frame(3));

    expect(sentBytes(sockets.single), [1, 1, 2, 2, 3, 3]);
    expect(client.pendingAudioBytes, 0);
  });

  test('held input waits for context, then follows it in order', () async {
    final client = makeClient();
    client.holdInput();
    client.sendAudio(frame(1));
    await client.connect();
    sockets.single.serverSends({'setupComplete': <String, dynamic>{}});
    await pumpEventQueue();
    expect(sockets.single.audioFrames, isEmpty);

    client.sendHistory(
      const [
        (fromUser: true, text: 'I met Maya.'),
        (fromUser: false, text: 'How was it?'),
      ],
      note: 'This continues an earlier conversation.',
    );
    client.releaseInput();

    final kinds = sockets.single.sent.skip(1).map((m) => m.keys.single);
    expect(kinds, ['client_content', 'realtime_input']);
    final context = sockets.single.sent[1]['client_content'] as Map;
    expect(context['turn_complete'], isFalse);
    expect(
      [for (final turn in context['turns'] as List) (turn as Map)['role']],
      ['user', 'model', 'user'],
    );
    expect(sentBytes(sockets.single), [1, 1]);
  });

  test('the pre-setup buffer is capped, dropping the oldest audio', () async {
    final client = makeClient();
    final second = Uint8List(GeminiLiveClient.maxPendingAudioBytes);
    client.sendAudio(frame(7));
    client.sendAudio(second);
    expect(client.pendingAudioBytes, GeminiLiveClient.maxPendingAudioBytes);
  });

  test('stores resumption handles and reconnects with the latest', () async {
    final client = makeClient();
    await client.connect();
    sockets.single.serverSends({'setupComplete': <String, dynamic>{}});
    sockets.single.serverSends({
      'sessionResumptionUpdate': {'newHandle': 'h1', 'resumable': true},
    });
    sockets.single.serverSends({
      'sessionResumptionUpdate': {'newHandle': 'h2', 'resumable': false},
    });
    await pumpEventQueue();
    expect(client.resumptionHandle, 'h1',
        reason: 'a non-resumable point never replaces a usable handle');

    var errors = 0;
    client.onError = (_) => errors++;
    await client.reconnect();

    expect(sockets, hasLength(2));
    expect(sockets.first.sinkImpl.closed, isTrue);
    expect(sockets.last.setup['session_resumption'], {'handle': 'h1'});
    expect(sockets.last.uri.queryParameters['access_token'], 'auth_tokens/one');
    expect(errors, 0, reason: 'our own close is not an error');
  });

  test('a reconnect can swap in a fresh token', () async {
    final client = makeClient(handle: 'h9');
    await client.connect();
    await client.reconnect(sessionToken: 'auth_tokens/two');

    expect(sockets.last.uri.queryParameters['access_token'], 'auth_tokens/two');
    expect(sockets.last.setup['session_resumption'], {'handle': 'h9'});
  });

  test('audio during a reconnect is buffered until the new setup', () async {
    final client = makeClient();
    await client.connect();
    sockets.single.serverSends({'setupComplete': <String, dynamic>{}});
    await pumpEventQueue();

    await client.reconnect();
    client.sendAudio(frame(4));
    expect(sockets.last.audioFrames, isEmpty);
    sockets.last.serverSends({'setupComplete': <String, dynamic>{}});
    await pumpEventQueue();

    expect(sentBytes(sockets.last), [4, 4]);
  });

  test('a socket closed before setup fails whenSetupComplete', () async {
    final client = makeClient();
    client.onError = (_) {};
    await client.connect();
    sockets.single.serverCloses();

    await expectLater(client.whenSetupComplete, throwsStateError);
  });

  test('audio stream end is sent when the mic pauses', () async {
    final client = makeClient();
    await client.connect();
    sockets.single.serverSends({'setupComplete': <String, dynamic>{}});
    await pumpEventQueue();

    client.sendAudioStreamEnd();

    expect(sockets.single.sent.last, {
      'realtime_input': {'audio_stream_end': true},
    });
  });
}
