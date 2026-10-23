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
import 'package:lumen/logic/turn_state.dart' hide CommitCommitted;
import 'package:lumen/models/follow_up.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/extract_graph_service.dart';
import 'package:lumen/services/extraction_context.dart';
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
  Future<void> start() async {}
  @override
  Future<void> schedule(Uint8List pcm16, int sampleRate) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class _FakeCommits implements NotebookCommitService {
  _FakeCommits(this.state);
  final JournalState state;
  int commits = 0;

  @override
  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async =>
      NotebookSnapshot(notebookId: notebookId, revision: 3, state: state);

  // Commits succeed, so the durable queue keeps moving past each turn.
  @override
  Future<CommitOutcome> commitNotebook({
    required String notebookId,
    required int expectedRevision,
    required String requestId,
    required NotebookChange change,
  }) async {
    commits += 1;
    return CommitCommitted(
      requestId: requestId,
      revision: expectedRevision + 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTurnJournal implements TurnJournalService {
  @override
  Future<void> persistTurn(FinalizedTurn turn) async {}

  @override
  Future<void> persistPreparedCommit({
    required FinalizedTurn turn,
    required PreparedTurnCommit preparedCommit,
  }) async {}

  @override
  Future<void> forgetTurn({required String notebookId, required String turnId}) async {}

  @override
  Future<List<TurnJournalCheckpoint>> loadCheckpoints(String notebookId) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records what reaches the extraction model.
class _FakeExtractor implements ExtractGraphService {
  final texts = <String>[];

  @override
  Future<GraphPatch> extract({
    required String notebookId,
    required String turnId,
    required String extractorVersion,
    required String text,
    required JournalState state,
    required String mode,
    List<({Speaker role, String text})> recentConversation = const [],
    List<String> retrievedEntityIds = const [],
    FollowUp? answeringFollowUp,
    int tokenBudget = defaultExtractionTokenBudget,
    int maxRetries = 2,
  }) async {
    texts.add(text);
    return GraphPatch.empty();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoMemory implements RetrieveMemoryService {
  @override
  Future<MemoryRetrieval> retrieveResult({
    required String query,
    required String notebookId,
    JournalState? state,
    RetrievalScope scope = RetrievalScope.notebook,
    Duration? timeout,
  }) async =>
      MemoryRetrieval.empty;

  @override
  Future<String> retrieve({
    required String query,
    required String notebookId,
    required JournalState state,
  }) async =>
      '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTranscripts implements TranscriptStore {
  _FakeTranscripts(this.turns);
  final List<ConversationTurn> turns;
  final saved = <ConversationTurn>[];

  @override
  Future<List<ConversationTurn>> load(String notebookId, {int limit = 500}) async =>
      turns;

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
  _Harness({
    JournalState? state,
    List<ConversationTurn> history = const [],
    Duration openingTimeout = const Duration(seconds: 10),
  })  : transcripts = _FakeTranscripts(history),
        commits = _FakeCommits(state ?? JournalState.empty()) {
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
      notebookCommitServiceProvider.overrideWithValue(commits),
      extractGraphServiceProvider.overrideWithValue(extractor),
      retrieveMemoryServiceProvider.overrideWithValue(_NoMemory()),
      turnJournalServiceProvider.overrideWithValue(_FakeTurnJournal()),
      transcriptStoreProvider.overrideWithValue(transcripts),
      openingTimeoutProvider.overrideWithValue(openingTimeout),
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

  final _FakeTranscripts transcripts;
  final _FakeCommits commits;
  final extractor = _FakeExtractor();
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

  test('a new notebook opens with Lumen joining, then greets', () async {
    h = _Harness();

    final entering = h.journal.enterNotebook(_notebookId);
    await h.waitForSocket(1);
    expect(h.journal.joining, JoiningPhase.joining);
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    final result = await entering;

    expect(result.succeeded, isTrue);
    expect(h.journal.joining, JoiningPhase.none);
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

  test('an old notebook opens quietly with its saved conversation', () async {
    h = _Harness(history: const [
      ConversationTurn(
        turnId: 'saved-1',
        role: Speaker.user,
        text: 'I met Maya.',
        createdAt: '2026-09-20T12:00:00.000Z',
      ),
      ConversationTurn(
        turnId: 'saved-2',
        role: Speaker.assistant,
        text: 'How did it go?',
        createdAt: '2026-09-20T12:00:05.000Z',
      ),
    ]);

    final entered = await h.journal.enterNotebook(_notebookId);

    expect(entered.succeeded, isTrue);
    expect(h.journal.status, SessionStatus.idle, reason: 'nothing auto-starts');
    expect(h.journal.joining, JoiningPhase.none);
    expect(h.sockets, isEmpty);
    expect(
      [for (final row in h.journal.transcriptRows) row.turn.text],
      ['I met Maya.', 'How did it go?'],
    );

    await h.startLive();
    final context = h.socket.sent[1]['client_content'] as Map;
    expect(
      [
        for (final turn in context['turns'] as List)
          ((turn as Map)['role'], ((turn['parts'] as List).single as Map)['text']),
      ],
      [
        ('user', 'I met Maya.'),
        ('model', 'How did it go?'),
        ('user', resumeNote),
      ],
    );
  });

  test('finalized turns from both speakers are saved once', () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    h.socket
      ..serverSends({
        'serverContent': {
          'inputTranscription': {'text': 'I finished the Atlas draft.', 'finished': true},
        },
      })
      ..serverSends({
        'serverContent': {
          'outputTranscription': {'text': 'How does it feel?', 'finished': true},
        },
      })
      ..serverSends({
        'serverContent': {'turnComplete': true},
      });
    for (var i = 0; i < 50 && h.transcripts.saved.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(
      [for (final turn in h.transcripts.saved) (turn.role, turn.text)],
      [
        (Speaker.user, 'I finished the Atlas draft.'),
        (Speaker.assistant, 'How does it feel?'),
      ],
    );
    // Later changes don't save them again.
    h.journal.toggleMute();
    h.socket.serverSends({'serverContent': {'turnComplete': true}});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(h.transcripts.saved, hasLength(2));
  });

  test("Lumen's turns commit without a model call of their own", () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    h.socket
      ..serverSends({
        'serverContent': {
          'inputTranscription': {
            'text': 'I finished the Atlas draft.',
            'finished': true,
          },
        },
      })
      ..serverSends({
        'serverContent': {
          'outputTranscription': {
            'text': 'How does it feel to be done?',
            'finished': true,
          },
        },
      })
      ..serverSends({
        'serverContent': {'turnComplete': true},
      });

    // Both turns commit (so the queue drained past Lumen's turn)…
    for (var i = 0; i < 200 && h.commits.commits < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(h.commits.commits, 2);
    // …but only the user's words were sent to the extraction model.
    expect(h.extractor.texts, ['I finished the Atlas draft.']);
  });

  test('Lumen not joining in time offers Retry, which can then succeed',
      () async {
    h = _Harness(openingTimeout: const Duration(milliseconds: 50));

    final entering = h.journal.enterNotebook(_notebookId);
    await h.waitForSocket(1);
    // No setup ack: the attempt times out.
    await entering;
    for (var i = 0; i < 50 && h.journal.status != SessionStatus.idle; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(h.journal.joining, JoiningPhase.failed);
    expect(h.journal.status, SessionStatus.idle);
    expect(h.sockets.single.sinkImpl.closed, isTrue);

    final retrying = h.journal.retryJoining();
    await h.waitForSocket(2);
    expect(h.journal.joining, JoiningPhase.joining);
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    expect((await retrying).succeeded, isTrue);
    expect(h.journal.joining, JoiningPhase.none);
    expect(h.journal.status, SessionStatus.live);
  });

  test('"Open without voice" drops the banner and leaves the mic idle',
      () async {
    h = _Harness(openingTimeout: const Duration(milliseconds: 50));

    final entering = h.journal.enterNotebook(_notebookId);
    await h.waitForSocket(1);
    await entering;
    for (var i = 0; i < 50 && h.journal.joining != JoiningPhase.failed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    await h.journal.openWithoutVoice();

    expect(h.journal.joining, JoiningPhase.none);
    expect(h.journal.status, SessionStatus.idle);
    expect(h.mic.recording, isFalse);
  });
}
