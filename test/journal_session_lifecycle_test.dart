// Phase 2 of the voice session lifecycle plan, end to end through the real
// JournalNotifier and GeminiLiveClient: only the socket, the microphone, the
// speaker and the token source are fakes.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/pcm_player.dart';
import 'package:lumen/logic/resume_context.dart';
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
import 'package:lumen/services/turn_journal_service.dart';

import 'support/fake_live_socket.dart';

const _notebookId = '8e03b8f4-4f20-4df3-8398-d854adc32b14';

class _FakeMic implements MicCapture {
  void Function(Uint8List)? _onChunk;
  int starts = 0;
  int stops = 0;
  bool get recording => _onChunk != null;

  void speak(int n) => _onChunk?.call(Uint8List.fromList([n, n]));

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<void> start(void Function(Uint8List pcm16) onChunk) async {
    starts += 1;
    _onChunk = onChunk;
  }

  @override
  Future<void> stop() async {
    stops += 1;
    _onChunk = null;
  }
}

class _Backend implements PcmAudioBackend {
  @override
  Future<void> setAudioStream(Stream<List<int>> stream) async {
    stream.listen((_) {});
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _FakeCommits implements NotebookCommitService {
  _FakeCommits(this.state);
  final JournalState state;

  @override
  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async =>
      NotebookSnapshot(notebookId: notebookId, revision: 3, state: state);

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

class _NoNotebookInserts implements SupabaseService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected Supabase call: ${invocation.memberName}');
}

class _Harness {
  _Harness({JournalState? state}) {
    credentials = LiveCredentials(fetch: () async {
      tokensMinted += 1;
      final now = DateTime.now();
      return LiveSessionReady(
        sessionToken: 'auth_tokens/t$tokensMinted',
        expiresAt: now.add(const Duration(minutes: 30)),
        newSessionExpiresAt: now.add(const Duration(minutes: 10)),
        model: 'gemini-3.1-flash-live-preview',
      );
    });
    container = ProviderContainer(overrides: [
      notebookCommitServiceProvider
          .overrideWithValue(_FakeCommits(state ?? JournalState.empty())),
      turnJournalServiceProvider.overrideWithValue(_FakeTurnJournal()),
      supabaseServiceProvider.overrideWithValue(_NoNotebookInserts()),
      liveCredentialsProvider.overrideWithValue(credentials),
      audioOutputProvider.overrideWithValue(
        AudioOutput(createPlayer: () => PcmPlayer(backend: _Backend())),
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

  late final ProviderContainer container;
  late final LiveCredentials credentials;
  final mic = _FakeMic();
  final sockets = <FakeLiveSocket>[];
  int tokensMinted = 0;

  JournalNotifier get journal => container.read(journalProvider.notifier);
  FakeLiveSocket get socket => sockets.last;

  Future<void> waitForSocket(int count) async {
    for (var i = 0; i < 200 && sockets.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(sockets, hasLength(count));
  }

  /// Taps the mic in the open notebook and plays the server's setup ack.
  Future<NotebookTransitionResult> startLive({void Function()? beforeSetup}) async {
    final starting = journal.startSession();
    await waitForSocket(sockets.length + 1);
    beforeSetup?.call();
    socket.serverSends({'setupComplete': <String, dynamic>{}});
    return starting;
  }

  void dispose() {
    credentials.stop();
    container.dispose();
  }
}

JournalEntry _entry(String text) => JournalEntry(
      id: 'entry-1',
      text: text,
      createdAt: DateTime.utc(2026, 9, 20, 12),
      entityIds: const [],
      relationIds: const [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;
  tearDown(() => h.dispose());

  test('a session never creates a notebook: no notebook, no session', () async {
    h = _Harness();

    final result = await h.journal.startSession();

    expect(result.succeeded, isFalse);
    expect(h.journal.status, SessionStatus.idle);
    expect(h.sockets, isEmpty);
    expect(h.mic.starts, 0);
  });

  test('a new notebook greets and sends no earlier context', () async {
    h = _Harness();
    await h.journal.enterNotebook(_notebookId);

    final result = await h.startLive();

    expect(result.succeeded, isTrue);
    expect(h.journal.status, SessionStatus.live);
    expect(h.socket.kindsAfterSetup, isNot(contains('client_content')));
    expect(
      h.journal.transcriptRows.where((row) => row.turn.turnId.startsWith('lumen-greeting')),
      hasLength(1),
      reason: 'the bundled greeting is Lumen\'s opening',
    );
  });

  test('an old notebook records from the tap, seeds context, then the audio',
      () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('I met Maya.')]),
    );
    await h.journal.enterNotebook(_notebookId);

    final starting = h.journal.startSession();
    await Future<void>.delayed(Duration.zero);
    // Spoken while Lumen is still connecting: nothing may be lost, and the
    // dock gives the user the floor rather than "Lumen · Connecting".
    expect(h.journal.status, SessionStatus.connecting);
    expect(h.journal.openingInProgress, isFalse);
    h.mic.speak(1);
    await h.waitForSocket(1);
    h.mic.speak(2);
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    expect((await starting).succeeded, isTrue);
    h.mic.speak(3);

    expect(h.journal.openingInProgress, isFalse, reason: 'no greeting');
    expect(
      h.journal.transcriptRows.where((row) => row.turn.turnId.startsWith('lumen-greeting')),
      isEmpty,
    );
    expect(h.socket.kindsAfterSetup.first, 'client_content');
    final context = h.socket.sent[1]['client_content'] as Map;
    expect(context['turn_complete'], isFalse);
    final texts = [
      for (final turn in context['turns'] as List)
        (((turn as Map)['parts'] as List).single as Map)['text'],
    ];
    expect(texts, ['I met Maya.', resumeNote]);
    expect(h.socket.sentAudioBytes, [1, 1, 2, 2, 3, 3]);
  });

  test('the mic pauses and resumes on the same connection', () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    await h.journal.pauseMic();
    expect(h.journal.status, SessionStatus.paused);
    expect(h.mic.recording, isFalse);
    expect(h.socket.sent.last, {
      'realtime_input': {'audio_stream_end': true},
    });

    final resumed = await h.journal.resumeMic();
    expect(resumed.succeeded, isTrue);
    expect(h.journal.status, SessionStatus.live);
    expect(h.mic.recording, isTrue);
    h.mic.speak(9);
    expect(h.socket.sentAudioBytes.last, 9);
    expect(h.sockets, hasLength(1), reason: 'no reconnect for a pause');
    expect(h.tokensMinted, 2, reason: 'one taken at the tap, one held');
  });

  test('goAway reconnects by handle with the same token, state unchanged',
      () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();
    final first = h.socket;
    first.serverSends({
      'sessionResumptionUpdate': {'newHandle': 'handle-1', 'resumable': true},
    });
    await Future<void>.delayed(Duration.zero);
    final minted = h.tokensMinted;

    first.serverSends({
      'goAway': {'timeLeft': '10s'},
    });
    await h.waitForSocket(2);
    expect(h.journal.reconnecting, isTrue);
    h.mic.speak(5); // said during the reconnect
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    for (var i = 0; i < 20 && h.journal.reconnecting; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(h.journal.reconnecting, isFalse);
    expect(h.journal.status, SessionStatus.live);
    expect(h.socket.setup['session_resumption'], {'handle': 'handle-1'});
    expect(h.socket.uri.queryParameters['access_token'],
        first.uri.queryParameters['access_token']);
    expect(h.tokensMinted, minted, reason: 'no new token inside 30 min');
    expect(h.socket.kindsAfterSetup, isNot(contains('client_content')),
        reason: 'context stays on Gemini\'s side');
    expect(h.socket.sentAudioBytes, [5, 5]);
  });

  test('a connection lost while paused comes back on resume', () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();
    h.socket.serverSends({
      'sessionResumptionUpdate': {'newHandle': 'handle-2', 'resumable': true},
    });
    await h.journal.pauseMic();

    h.socket.serverCloses();
    await Future<void>.delayed(Duration.zero);
    expect(h.journal.status, SessionStatus.paused, reason: 'no error shown');
    expect(h.sockets, hasLength(1));

    final resuming = h.journal.resumeMic();
    await h.waitForSocket(2);
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    expect((await resuming).succeeded, isTrue);
    expect(h.journal.status, SessionStatus.live);
    expect(h.socket.setup['session_resumption'], {'handle': 'handle-2'});
  });

  test('End ends the voice session but keeps the notebook open', () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    final ended = await h.journal.endSession();
    expect(ended.succeeded, isTrue);
    expect(h.journal.status, SessionStatus.idle);
    expect(h.mic.recording, isFalse);
    expect(h.socket.sinkImpl.closed, isTrue);

    // The next tap continues in the same notebook.
    final again = await h.startLive();
    expect(again.succeeded, isTrue);
    expect(h.sockets, hasLength(2));
    expect(h.socket.kindsAfterSetup.first, 'client_content');
  });
}
