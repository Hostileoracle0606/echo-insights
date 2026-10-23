// LM-07: get_relevant_memory through the real JournalNotifier and
// GeminiLiveClient. Only the socket, microphone, speaker, token source and
// the retrieve-memory call are fakes.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/pcm_player.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/session_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/gemini_live_client.dart';
import 'package:lumen/services/live_credentials.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/notebook_runtime_service.dart';
import 'package:lumen/services/retrieve_memory_service.dart';
import 'package:lumen/services/supabase_service.dart';
import 'package:lumen/services/transcript_store.dart';
import 'package:lumen/services/turn_journal_service.dart';

import 'support/fake_live_socket.dart';

const _notebookId = '8e03b8f4-4f20-4df3-8398-d854adc32b14';

Map<String, dynamic> _fixture(String name) => jsonDecode(
      File('contracts/fixtures/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

class _FakeMic implements MicCapture {
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<void> start(void Function(Uint8List pcm16) onChunk) async {}
  @override
  Future<void> stop() async {}
}

class _Backend implements PcmAudioBackend {
  @override
  Future<void> start() async {}
  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) async {}
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
        revision: 1,
        state: JournalState.empty(),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTurnJournal implements TurnJournalService {
  @override
  Future<List<TurnJournalCheckpoint>> loadCheckpoints(String notebookId) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTranscripts implements TranscriptStore {
  @override
  Future<List<ConversationTurn>> load(String notebookId, {int limit = 500}) async =>
      const [];

  @override
  Future<void> save(String notebookId, ConversationTurn turn) async {}
}

class _NoNotebookInserts implements SupabaseService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected Supabase call: ${invocation.memberName}');
}

class _Harness {
  _Harness(RetrieveMemoryInvoker retrieve) {
    credentials = LiveCredentials(fetch: () async {
      final now = DateTime.now();
      return LiveSessionReady(
        sessionToken: 'auth_tokens/t1',
        expiresAt: now.add(const Duration(minutes: 30)),
        newSessionExpiresAt: now.add(const Duration(minutes: 10)),
        model: 'gemini-3.1-flash-live-preview',
      );
    });
    container = ProviderContainer(overrides: [
      notebookCommitServiceProvider.overrideWithValue(_FakeCommits()),
      turnJournalServiceProvider.overrideWithValue(_FakeTurnJournal()),
      transcriptStoreProvider.overrideWithValue(_FakeTranscripts()),
      supabaseServiceProvider.overrideWithValue(_NoNotebookInserts()),
      liveCredentialsProvider.overrideWithValue(credentials),
      audioOutputProvider.overrideWithValue(
        AudioOutput(createPlayer: () => PcmPlayer(backend: _Backend())),
      ),
      micCaptureFactoryProvider.overrideWithValue(() => _FakeMic()),
      retrieveMemoryServiceProvider.overrideWithValue(
        RetrieveMemoryService.withInvoker((body) {
          requests.add(body);
          return retrieve(body);
        }),
      ),
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

  late final ProviderContainer container;
  late final LiveCredentials credentials;
  final sockets = <FakeLiveSocket>[];
  final requests = <Map<String, dynamic>>[];

  JournalNotifier get journal => container.read(journalProvider.notifier);
  FakeLiveSocket get socket => sockets.last;

  Future<void> openLive() async {
    final entering = journal.enterNotebook(_notebookId);
    for (var i = 0; i < 200 && sockets.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    socket.serverSends({'setupComplete': <String, dynamic>{}});
    expect((await entering).succeeded, isTrue);
    expect(journal.status, SessionStatus.live);
  }

  /// Gemini calls get_relevant_memory; returns what the app answered.
  Future<Map<String, dynamic>> recall(String query, {String id = 'c1'}) async {
    socket.serverSends({
      'toolCall': {
        'functionCalls': [
          {
            'id': id,
            'name': 'get_relevant_memory',
            'args': {'query': query},
          },
        ],
      },
    });
    for (var i = 0; i < 200; i++) {
      for (final message in socket.sent) {
        final responses = (message['tool_response'] as Map?)?['function_responses'];
        if (responses is List && responses.isNotEmpty) {
          final response = responses.single as Map;
          if (response['id'] == id) {
            return ((response['response'] as Map)['output'] as Map)
                .cast<String, dynamic>();
          }
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    fail('no tool response for $id');
  }

  void dispose() {
    credentials.stop();
    container.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;
  tearDown(() => h.dispose());

  test('recall asks user scope and gives the model dated quotes, never ids',
      () async {
    h = _Harness((_) async => _fixture('retrieve-memory-v2.success.json'));
    await h.openLive();

    final output = await h.recall('Priya');

    expect(h.requests.single, {
      'query': 'Priya',
      'notebookId': _notebookId,
      'scope': 'user',
    });
    expect(output.keys, unorderedEquals(['context', 'quotes']));
    final quotes = (output['quotes'] as List).cast<Map>();
    expect(quotes, hasLength(2));
    for (final quote in quotes) {
      expect(quote.keys, unorderedEquals(['when', 'text']));
      expect(quote['when'], matches(RegExp(r'^\w{3}, \w{3} \d+')));
    }
    expect(quotes.first['text'], startsWith('Priya said the CI fix is next'));
    final encoded = jsonEncode(output);
    expect(encoded, isNot(contains('2c7d6a51')), reason: 'no entry id');
    expect(encoded, isNot(contains('6f1c0a9e')), reason: 'no notebook id');
    expect(encoded, isNot(contains('turn-7f3a')), reason: 'no turn id');
  });

  test('a recall with entities is remembered for the UI, until the session ends',
      () async {
    h = _Harness((_) async => _fixture('retrieve-memory-v2.success.json'));
    await h.openLive();
    expect(h.container.read(recallActivityProvider), isNull);

    await h.recall('Priya', id: 'c1');
    final first = h.container.read(recallActivityProvider)!;
    expect(first.seq, 1);
    expect(first.entityIds, ['priya', 'ci-fix']);
    expect(first.quotes.map((q) => q.entryId), [
      '2c7d6a51-3f0e-4c1b-9f43-8a1de2b7c901',
      '9b8e0f12-6c4d-4a7e-8b1f-2d3c4e5f6a70',
    ]);
    expect(first.quotes.first.notebookId, '6f1c0a9e-1b2d-4e8f-a3c4-5d6e7f809a1b');

    await h.recall('the CI fix', id: 'c2');
    expect(h.container.read(recallActivityProvider)!.seq, 2);

    await h.journal.endSession();
    expect(h.container.read(recallActivityProvider), isNull);
  });

  test('empty memory leaves recall unset', () async {
    h = _Harness((_) async => _fixture('retrieve-memory-v2.empty.json'));
    await h.openLive();

    final output = await h.recall('Priya');

    expect(output, {'context': '', 'quotes': <dynamic>[]});
    expect(h.journal.recall, isNull);
  });

  test('a failed lookup answers empty and leaves recall unset', () async {
    h = _Harness((_) async => throw const SocketException('offline'));
    await h.openLive();

    final output = await h.recall('Priya');

    expect(output, {'context': '', 'quotes': <dynamic>[]});
    expect(h.journal.recall, isNull);
  });
}
