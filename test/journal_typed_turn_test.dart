// LM-12: typed turns through the real JournalNotifier and GeminiLiveClient.
// Only the socket, the microphone, the speaker and the token source are
// fakes. The server sequences played here are the ones recorded against the
// real Gemini Live by test/gemini_live_typed_turn_probe.dart.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/pcm_player.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/gemini_live_client.dart';
import 'package:lumen/services/live_credentials.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/notebook_runtime_service.dart';
import 'package:lumen/services/supabase_service.dart';
import 'package:lumen/services/transcript_store.dart';
import 'package:lumen/services/turn_journal_service.dart';

import 'support/fake_live_socket.dart';

const _notebookId = '8e03b8f4-4f20-4df3-8398-d854adc32b14';

class _FakeMic implements MicCapture {
  void Function(Uint8List)? _onChunk;
  bool get recording => _onChunk != null;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start(void Function(Uint8List pcm16) onChunk) async =>
      _onChunk = onChunk;

  @override
  Future<void> stop() async => _onChunk = null;
}

/// The speaker: counts the audio chunks scheduled on it.
class _Speaker implements PcmAudioBackend {
  int chunks = 0;

  @override
  Future<void> start() async {}
  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) async => chunks += 1;
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _FakeCommits implements NotebookCommitService {
  @override
  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async =>
      NotebookSnapshot(
        notebookId: notebookId,
        revision: 3,
        // Continuing a notebook: no greeting, the user has the floor.
        state: JournalState.empty().copyWith(entries: [
          JournalEntry(
            id: 'entry-1',
            text: 'Earlier.',
            createdAt: DateTime.utc(2026, 10, 20, 12),
            entityIds: const [],
            relationIds: const [],
          ),
        ]),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTurnJournal implements TurnJournalService {
  @override
  Future<void> persistTurn(FinalizedTurn turn) async {}

  @override
  Future<void> forgetTurn({
    required String notebookId,
    required String turnId,
  }) async {}

  @override
  Future<List<TurnJournalCheckpoint>> loadCheckpoints(String notebookId) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTranscripts implements TranscriptStore {
  final saved = <ConversationTurn>[];

  @override
  Future<List<ConversationTurn>> load(String notebookId, {int limit = 500}) async =>
      const [];

  @override
  Future<void> save(String notebookId, ConversationTurn turn) async =>
      saved.add(turn);
}

class _NoNotebookInserts implements SupabaseService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected Supabase call: ${invocation.memberName}');
}

class _Harness {
  _Harness() {
    credentials = LiveCredentials(fetch: () async {
      final now = DateTime.now();
      return LiveSessionReady(
        sessionToken: 'auth_tokens/t${now.microsecondsSinceEpoch}',
        expiresAt: now.add(const Duration(minutes: 30)),
        newSessionExpiresAt: now.add(const Duration(minutes: 10)),
        model: 'gemini-3.1-flash-live-preview',
      );
    });
    container = ProviderContainer(overrides: [
      notebookCommitServiceProvider.overrideWithValue(_FakeCommits()),
      turnJournalServiceProvider.overrideWithValue(_FakeTurnJournal()),
      transcriptStoreProvider.overrideWithValue(transcripts),
      supabaseServiceProvider.overrideWithValue(_NoNotebookInserts()),
      liveCredentialsProvider.overrideWithValue(credentials),
      audioOutputProvider.overrideWithValue(
        AudioOutput(createPlayer: () => PcmPlayer(backend: speaker)),
      ),
      micCaptureFactoryProvider.overrideWithValue(() => mic),
      liveClientFactoryProvider.overrideWithValue(
        ({required String sessionToken, required String model}) =>
            GeminiLiveClient(
          sessionToken: sessionToken,
          model: model,
          systemInstruction: 'system',
          voice: 'Aoede',
          tools: const [],
          channelFactory: (uri) {
            final socket = FakeLiveSocket(uri);
            sockets.add(socket);
            return socket;
          },
        ),
      ),
    ]);
    credentials.start();
  }

  final transcripts = _FakeTranscripts();
  final speaker = _Speaker();
  late final ProviderContainer container;
  late final LiveCredentials credentials;
  final mic = _FakeMic();
  final sockets = <FakeLiveSocket>[];

  JournalNotifier get journal => container.read(journalProvider.notifier);
  FakeLiveSocket get socket => sockets.last;

  Future<void> waitForSocket(int count) async {
    for (var i = 0; i < 200 && sockets.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(sockets, hasLength(count));
  }

  /// Opens the notebook and starts a live session on the first socket.
  Future<void> startLive() async {
    await journal.enterNotebook(_notebookId);
    final starting = journal.startSession();
    await waitForSocket(1);
    socket
      ..serverSends({'setupComplete': <String, dynamic>{}})
      ..serverSends({
        'sessionResumptionUpdate': {'newHandle': 'handle-1', 'resumable': true},
      });
    expect((await starting).succeeded, isTrue);
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  void dispose() {
    credentials.stop();
    container.dispose();
  }
}

/// The text of every typed turn sent to Gemini on [socket], in order.
List<String> _typedSent(FakeLiveSocket socket) => [
      for (final message in socket.sent)
        if (message['client_content'] case {
          'turns': [
            {'role': 'user', 'parts': [{'text': final String text}]},
          ],
          'turn_complete': true,
        })
          text,
    ];

/// One streamed chunk of Lumen's output transcription.
Map<String, dynamic> _lumenSays(String text) => {
      'serverContent': {
        'outputTranscription': {'text': text},
      },
    };

Map<String, dynamic> _lumenAudio() => {
      'serverContent': {
        'modelTurn': {
          'parts': [
            {
              'inlineData': {
                'mimeType': 'audio/pcm;rate=24000',
                // 0.5 s of silence: long enough to still be playing.
                'data': base64.encode(Uint8List(24000)),
              },
            },
          ],
        },
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;
  tearDown(() => h.dispose());

  test('a typed turn goes to Gemini on the same connection, mic still paused',
      () async {
    h = _Harness();
    await h.startLive();
    await h.journal.pauseMic();

    final sent = h.journal.sendTypedTurn('  Maya signed off on the launch.  ');

    expect(sent, isTrue);
    expect(_typedSent(h.socket), ['Maya signed off on the launch.']);
    expect(h.sockets, hasLength(1), reason: 'no reconnect for a typed turn');
    expect(h.journal.status, SessionStatus.paused);
    expect(h.mic.recording, isFalse);

    final turn = h.journal.conversation.single;
    expect((turn.role, turn.text, turn.input),
        (Speaker.user, 'Maya signed off on the launch.', TurnInput.typed));
    await h.settle();
    expect(h.transcripts.saved.single.input, TurnInput.typed);
  });

  test('blank text, or no live session, sends nothing', () async {
    h = _Harness();
    await h.journal.enterNotebook(_notebookId);
    expect(h.journal.sendTypedTurn('Hello'), isFalse, reason: 'no session');

    final starting = h.journal.startSession();
    await h.waitForSocket(1);
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    await starting;

    expect(h.journal.sendTypedTurn('   '), isFalse);
    expect(_typedSent(h.socket), isEmpty);
    expect(h.journal.conversation, isEmpty);
  });

  test('typing over Lumen stops its voice, and the cut-off reply stays cut',
      () async {
    h = _Harness();
    await h.startLive();
    h.socket
      ..serverSends(_lumenSays('You mentioned Acme. '))
      ..serverSends(_lumenAudio());
    await h.settle();
    expect(h.journal.agentSpeaking, isTrue);
    expect(h.journal.liveAgentText, isNotEmpty);
    final heardBefore = h.speaker.chunks;

    h.journal.sendTypedTurn('Wait, which Acme?');
    await h.settle();

    expect(h.journal.agentSpeaking, isFalse, reason: 'playback was flushed');
    expect(h.journal.liveAgentText, isEmpty);
    expect(_typedSent(h.socket), ['Wait, which Acme?']);

    // The cut-off reply's tail still arrives before Gemini reports the cut.
    h.socket
      ..serverSends(_lumenSays('Your sister Mia lives in Oslo.'))
      ..serverSends(_lumenAudio())
      ..serverSends({'serverContent': {'interrupted': true}})
      ..serverSends({'serverContent': {'turnComplete': true}});
    await h.settle();
    expect(h.speaker.chunks, heardBefore, reason: 'the tail is never played');

    // Then Lumen answers the typed turn, and is heard again.
    h.socket
      ..serverSends(_lumenSays('The client, '))
      ..serverSends(_lumenSays('Acme Robotics.'))
      ..serverSends(_lumenAudio())
      ..serverSends({'serverContent': {'turnComplete': true}});
    await h.settle();
    expect(h.speaker.chunks, greaterThan(heardBefore));

    final texts = [for (final row in h.journal.transcriptRows) row.turn.text];
    expect(texts.join(' '), isNot(contains('Oslo')));
    expect(texts, containsAllInOrder(['Wait, which Acme?', 'The client, Acme Robotics.']));
  });

  test('typed turns sent while reconnecting go out in order once it is back',
      () async {
    h = _Harness();
    await h.startLive();
    final first = h.socket;
    first.serverSends({'goAway': {'timeLeft': '10s'}});
    await h.waitForSocket(2);
    expect(h.journal.reconnecting, isTrue);

    expect(h.journal.sendTypedTurn('One.'), isTrue);
    expect(h.journal.sendTypedTurn('Two.'), isTrue);
    expect(_typedSent(first), isEmpty);
    expect(_typedSent(h.socket), isEmpty, reason: 'not before setup');
    expect(
      [for (final t in h.journal.conversation) t.text],
      ['One.', 'Two.'],
      reason: 'recorded when typed, not when sent',
    );

    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    for (var i = 0; i < 20 && h.journal.reconnecting; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(h.journal.reconnecting, isFalse);
    expect(_typedSent(h.socket), ['One.', 'Two.']);
  });

  test('a connection that lapsed with the composer open comes back to send',
      () async {
    h = _Harness();
    await h.startLive();
    await h.journal.pauseMic();
    h.socket.serverCloses();
    await h.settle();
    expect(h.sockets, hasLength(1), reason: 'paused: nothing reconnects yet');

    expect(h.journal.sendTypedTurn('Still there?'), isTrue);
    await h.waitForSocket(2);
    expect(h.socket.setup['session_resumption'], {'handle': 'handle-1'});
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    await h.settle();

    expect(_typedSent(h.socket), ['Still there?']);
    expect(h.journal.status, SessionStatus.paused, reason: 'the mic stays off');
    expect(h.mic.recording, isFalse);
  });

  test('a typed turn a failed reconnect never sent is context, not a new turn',
      () async {
    h = _Harness();
    await h.startLive();
    await h.journal.pauseMic();
    h.socket.serverCloses();
    await h.settle();

    h.journal.sendTypedTurn('Lost in transit.');
    // Every reconnect attempt dies before setup.
    for (var attempt = 2; attempt <= 4; attempt++) {
      await h.waitForSocket(attempt);
      h.socket.serverCloses();
      for (var i = 0; i < 400 && h.sockets.length == attempt; i++) {
        if (h.journal.status == SessionStatus.error) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    expect(h.journal.status, SessionStatus.error);

    final starting = h.journal.startSession();
    await h.waitForSocket(5);
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    expect((await starting).succeeded, isTrue);
    await h.settle();

    expect(_typedSent(h.socket), isEmpty, reason: 'not replayed as a turn');
    final context = h.socket.sent
        .map((m) => m['client_content'])
        .whereType<Map<String, dynamic>>()
        .where((c) => c['turn_complete'] == false)
        .single;
    expect(jsonEncode(context['turns']), contains('Lost in transit.'));

    // Nor on the new session's next reconnect.
    h.socket
      ..serverSends({
        'sessionResumptionUpdate': {'newHandle': 'handle-5', 'resumable': true},
      })
      ..serverSends({'goAway': {'timeLeft': '10s'}});
    await h.waitForSocket(6);
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    for (var i = 0; i < 20 && h.journal.reconnecting; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(h.journal.reconnecting, isFalse);
    expect(_typedSent(h.socket), isEmpty, reason: 'not replayed later either');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
