// LM-50, off the record: end to end through the real JournalNotifier and
// GeminiLiveClient. Only the socket, the microphone, the speaker, the token
// source and the backends are fakes, and every backend write is counted.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/pcm_player.dart';
import 'package:lumen/logic/context_materialiser.dart' show WorkingFact;
import 'package:lumen/logic/context_rebuild_policy.dart';
import 'package:lumen/logic/turn_state.dart' hide CommitCommitted;
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/follow_up.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/models/session_card.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/providers/session_provider.dart';
import 'package:lumen/providers/shared_log_provider.dart';
import 'package:lumen/services/shared_log.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/extract_graph_service.dart';
import 'package:lumen/services/extraction_context.dart';
import 'package:lumen/services/gemini_live_client.dart';
import 'package:lumen/services/live_credentials.dart';
import 'package:lumen/services/conversation_state_service.dart';
import 'package:lumen/services/memory_correction_service.dart';
import 'package:lumen/services/memory_fact_service.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/notebook_runtime_service.dart';
import 'package:lumen/services/retrieve_memory_service.dart';
import 'package:lumen/services/session_brief_service.dart';
import 'package:lumen/services/session_card_service.dart';
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

  /// Runs as the mic stops, with its callback still wired: a frame already
  /// on its way when the session fails.
  void Function()? onStop;

  @override
  Future<void> stop() async {
    stops += 1;
    onStop?.call();
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
  List<String> suppressedIds = const [];

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
      entryId: 'server-entry-$commits',
      suppressedIds: suppressedIds,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTurnJournal implements TurnJournalService {
  int writes = 0;

  @override
  Future<void> persistTurn(FinalizedTurn turn) async => writes += 1;

  @override
  Future<void> persistPreparedCommit({
    required FinalizedTurn turn,
    required PreparedTurnCommit preparedCommit,
  }) async =>
      writes += 1;

  @override
  Future<void> forgetTurn(
      {required String notebookId, required String turnId}) async {}

  @override
  Future<List<TurnJournalCheckpoint>> loadCheckpoints(
          String notebookId) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// LM-57: counts what would be logged. Nothing is sent off the record, so
/// nothing may be recorded.
class _CountingLog implements SharedLog {
  final List<SharedKind> recorded = [];

  @override
  Future<void> record(
    String notebookId,
    SharedKind kind,
    Map<String, dynamic> body,
  ) async {
    recorded.add(kind);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records what reaches the extraction model.
class _FakeExtractor implements ExtractGraphService {
  final texts = <String>[];
  final contexts = <List<String>>[];
  final spokenAts = <DateTime?>[];
  GraphPatch result = GraphPatch.empty();

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
    DateTime? spokenAt,
  }) async {
    texts.add(text);
    contexts.add([for (final turn in recentConversation) turn.text]);
    spokenAts.add(spokenAt);
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// EC-07: corrections proposed, applied and rejected.
class _FakeCorrections implements MemoryCorrectionService {
  final proposed = <Map<String, dynamic>>[];
  final applied = <String>[];
  final rejected = <String>[];

  @override
  Future<Map<String, dynamic>> propose({
    required String about,
    String? attribute,
    required Map<String, dynamic> change,
  }) async {
    proposed.add({'about': about, 'attribute': attribute, 'change': change});
    if (about == 'nothing stored') return {'status': 'not_found'};
    return {
      'status': 'pending',
      'correctionId': 'c-${proposed.length}',
      'readBack': 'So your savings goal amount is 7000 USD, not 8000 USD. Is that right?',
    };
  }

  @override
  Future<Map<String, dynamic>> apply(String correctionId) async {
    applied.add(correctionId);
    return {'status': 'applied'};
  }

  @override
  Future<Map<String, dynamic>> reject(String correctionId) async {
    rejected.add(correctionId);
    return {'status': 'rejected', 'offerRemoval': rejected.length >= 2};
  }
}

/// EC-04: the session state record's saves and clears.
class _FakeConversationState implements ConversationStateService {
  final saved = <Map<String, dynamic>>[];
  final cleared = <String>[];
  Map<String, dynamic>? stored;

  @override
  Future<void> save(String notebookId, Map<String, dynamic> state) async {
    saved.add(state);
  }

  @override
  Future<Map<String, dynamic>?> load(String notebookId) async => stored;

  @override
  Future<void> clear(String notebookId) async => cleared.add(notebookId);
}

/// EC-03: the facts recorded after a commit.
class _FakeFacts implements MemoryFactService {
  final calls = <({String notebookId, String entryId, List<Map<String, dynamic>> facts})>[];

  @override
  Future<void> recordFacts({
    required String notebookId,
    required String entryId,
    required List<Map<String, dynamic>> facts,
  }) async {
    calls.add((notebookId: notebookId, entryId: entryId, facts: facts));
  }

  List<WorkingFact> current = const [];

  @override
  Future<List<WorkingFact>> currentFacts(List<String> entityIds) async => current;
}

class _NoMemory implements RetrieveMemoryService {
  @override
  Future<MemoryRetrieval> retrieveResult({
    required String query,
    required String notebookId,
    String? question,
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
  Future<List<ConversationTurn>> load(String notebookId,
          {int limit = 500}) async =>
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

/// Records notebooks marked ended or removed; any other call fails the test.
class _EndingNotebooks implements SupabaseService {
  final ended = <String>[];
  final deleted = <String>[];
  Object? deleteFails;

  @override
  Future<void> endNotebook(String notebookId) async => ended.add(notebookId);

  @override
  Future<bool> deleteEmptyNotebook(String notebookId) async {
    deleted.add(notebookId);
    final failure = deleteFails;
    if (failure != null) throw failure;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      fail('unexpected Supabase call: ${invocation.memberName}');
}

/// Records close-session requests; [onClose] decides how each one ends.
class _FakeCards implements SessionCardService {
  final closed = <String>[];
  final drafted = <String>[];
  Future<SessionCard?> Function(String notebookId)? onClose;

  @override
  Future<SessionCard?> close(String notebookId, {int maxRetries = 2}) {
    closed.add(notebookId);
    return onClose?.call(notebookId) ?? Future.value(null);
  }

  @override
  Future<SessionCard?> draft(String notebookId) {
    drafted.add(notebookId);
    return Future.value(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The session-brief backend: [state] is what the sign-in load returns
/// (null: the load fails), and every write is recorded.
class _FakeBriefs implements SessionBriefService {
  SessionOpeningState? state;
  int loads = 0;
  final requested = <String>[];
  final played = <DateTime>[];
  Future<void> Function(String notebookId)? onRequest;

  @override
  Future<SessionOpeningState> load() async {
    loads += 1;
    final loaded = state;
    if (loaded == null) throw StateError('no brief state');
    return loaded;
  }

  @override
  Future<void> requestBrief(String notebookId) {
    requested.add(notebookId);
    return onRequest?.call(notebookId) ?? Future.value();
  }

  @override
  Future<void> markPlayed(DateTime createdAt) async => played.add(createdAt);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({
    JournalState? state,
    List<ConversationTurn> history = const [],
    Duration openingTimeout = const Duration(seconds: 10),
    SupabaseService? supabase,
    ContextRebuildConfig? rebuild,
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
      memoryFactServiceProvider.overrideWithValue(facts),
      conversationStateServiceProvider.overrideWithValue(sessionState),
      memoryCorrectionServiceProvider.overrideWithValue(corrections),
      sharedLogProvider.overrideWithValue(sharedLog),
      retrieveMemoryServiceProvider.overrideWithValue(_NoMemory()),
      turnJournalServiceProvider.overrideWithValue(journal_),
      transcriptStoreProvider.overrideWithValue(transcripts),
      openingTimeoutProvider.overrideWithValue(openingTimeout),
      supabaseServiceProvider
          .overrideWithValue(supabase ?? _NoNotebookInserts()),
      sessionCardServiceProvider.overrideWithValue(cards),
      sessionBriefServiceProvider.overrideWithValue(briefs),
      liveCredentialsProvider.overrideWithValue(credentials),
      contextRebuildConfigProvider.overrideWithValue(rebuild),
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

  final journal_ = _FakeTurnJournal();
  final _FakeTranscripts transcripts;
  final _FakeCommits commits;
  final extractor = _FakeExtractor();
  final facts = _FakeFacts();
  final sessionState = _FakeConversationState();
  final corrections = _FakeCorrections();
  final sharedLog = _CountingLog();
  final cards = _FakeCards();
  final briefs = _FakeBriefs();
  late final ProviderContainer container;
  late final LiveCredentials credentials;
  final mic = _FakeMic();
  final sockets = <FakeLiveSocket>[];
  int tokensMinted = 0;

  JournalNotifier get journal => container.read(journalProvider.notifier);
  OpeningPrep get prep => container.read(openingPrepProvider);
  FakeLiveSocket get socket => sockets.last;

  Future<void> waitForSocket(int count) async {
    for (var i = 0; i < 200 && sockets.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(sockets, hasLength(count));
  }

  /// Taps the mic in the open notebook and plays the server's setup ack.
  Future<NotebookTransitionResult> startLive(
      {void Function()? beforeSetup}) async {
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

const _oldNotebook = ConversationTurn(
  turnId: 'old-turn',
  role: Speaker.user,
  text: 'An earlier session.',
  createdAt: '2026-09-20T12:00:00Z',
);

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Every backend write the ticket forbids while off the record.
void _expectNoWrites(_Harness h) {
  expect(h.commits.commits, 0, reason: 'commit RPC');
  expect(h.cards.drafted, isEmpty, reason: 'card draft');
  expect(h.cards.closed, isEmpty, reason: 'final card');
  expect(h.briefs.requested, isEmpty, reason: 'brief request');
  expect(h.journal_.writes, 0, reason: 'turn journal');
  expect(h.transcripts.saved, isEmpty, reason: 'transcript store');
  expect(h.extractor.texts, isEmpty, reason: 'extraction');
  expect(h.facts.calls, isEmpty, reason: 'facts (EC-03)');
  expect(h.sessionState.saved, isEmpty, reason: 'session state (EC-04)');
  expect(h.corrections.proposed, isEmpty, reason: 'corrections (EC-07)');
  expect(h.sharedLog.recorded, isEmpty,
      reason: 'What Lumen shared log (LM-57)');
}

Future<void> _waitForCommits(_Harness h, int count) async {
  for (var i = 0; i < 200 && h.commits.commits < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;
  tearDown(() => h.dispose());

  /// A fresh notebook, opened off the record and live.
  Future<void> openFreshOffTheRecord(_Harness h) async {
    final entering = h.journal.enterNotebook(_notebookId, offTheRecord: true);
    await h.waitForSocket(1);
    h.socket.serverSends({'setupComplete': <String, dynamic>{}});
    expect((await entering).succeeded, isTrue);
  }

  void userSaysAndLumenReplies(_Harness h, String user, String lumen) {
    h.socket
      ..serverSends({
        'serverContent': {
          'inputTranscription': {'text': user, 'finished': true},
        },
      })
      ..serverSends({
        'serverContent': {
          'outputTranscription': {'text': lumen, 'finished': true},
        },
      })
      ..serverSends({
        'serverContent': {'turnComplete': true},
      });
  }

  test('a fully off-the-record session makes no write, and leaves nothing',
      () async {
    final notebooks = _EndingNotebooks();
    h = _Harness(supabase: notebooks);
    await openFreshOffTheRecord(h);
    expect(h.journal.offTheRecord, isTrue);

    userSaysAndLumenReplies(h, 'I told nobody about Atlas.', 'Go on.');
    expect(h.journal.sendTypedTurn('Typed secret.'), isTrue);
    await _settle();

    _expectNoWrites(h);
    // On screen for the session, and in the conversation Gemini holds.
    final onScreen = [
      for (final row in h.journal.transcriptRows) row.turn.text
    ];
    expect(onScreen, containsAll(['I told nobody about Atlas.', 'Go on.']));
    expect(onScreen, contains('Typed secret.'));
    expect(h.journal.conversation, isEmpty,
        reason: 'not in the saved conversation');

    final left = await h.journal.leaveNotebook();
    await _settle();

    expect(left.succeeded, isTrue);
    expect(left.nothingSaved, isTrue);
    // The one accepted write at leave (R12): a single delete RPC, nothing else.
    expect(notebooks.deleted, [_notebookId], reason: 'the empty row goes');
    expect(notebooks.ended, isEmpty);
    _expectNoWrites(h);
    expect(
      [for (final row in h.journal.transcriptRows) row.turn.text],
      everyElement(isNot(anyOf(contains('Atlas'), contains('secret')))),
      reason: 'forgotten on leave',
    );
    expect(h.journal.offTheRecord, isFalse, reason: 'the next visit is on');
  });

  test('a commit the server thinned drops the person from the device',
      () async {
    h = _Harness(
      state: JournalState.empty().copyWith(
        entries: [_entry('Earlier.')],
        entities: {
          'maya-chen': Entity(
            id: 'maya-chen',
            name: 'Maya Chen',
            type: EntityType.person,
            description: null,
            metadata: const {},
            mentions: 1,
            firstSeen: DateTime(2026, 10, 20),
            lastSeen: DateTime(2026, 10, 20),
          ),
        },
      ),
      supabase: _EndingNotebooks(),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();
    h.commits.suppressedIds = const ['maya-chen'];

    expect(h.journal.sendTypedTurn('I saw Maya Chen.'), isTrue);
    await _waitForCommits(h, 1);
    await _settle();

    expect(h.container.read(journalProvider).entities, isEmpty);
    expect(h.journal.suppressedEntityIds, contains('maya-chen'));
    expect(h.container.read(forgottenThisRunProvider), contains('maya-chen'));
  });

  test('a committed turn records its facts against the server entry (EC-03)',
      () async {
    h = _Harness(supabase: _EndingNotebooks());
    h.extractor.result = const GraphPatch(
      entities: [EntityPatch(name: 'savings goal', type: EntityType.concept)],
      relations: [],
      supersedes: [],
      facts: [
        FactPatch(
          entity: 'savings goal',
          attribute: 'amount',
          valueNum: 8000,
          unit: 'USD',
          status: 'confirmed',
        ),
      ],
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    expect(h.journal.sendTypedTurn('My savings goal is 8k now.'), isTrue);
    await _waitForCommits(h, 1);
    await _settle();

    expect(h.extractor.spokenAts.single, isNotNull,
        reason: 'the model resolves "yesterday" from when the turn was said');
    final call = h.facts.calls.single;
    expect(call.notebookId, _notebookId);
    expect(call.entryId, 'server-entry-1');
    expect(call.facts, [
      {
        'entityId': 'savings-goal',
        'attribute': 'amount',
        'valueNum': 8000,
        'unit': 'USD',
        'status': 'confirmed',
      },
    ]);
  });

  test('a turn with no facts records nothing', () async {
    h = _Harness(supabase: _EndingNotebooks());
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();
    expect(h.journal.sendTypedTurn('Just a quiet day.'), isTrue);
    await _waitForCommits(h, 1);
    await _settle();
    expect(h.facts.calls, isEmpty);
  });

  /// Gemini calls [name]; returns what the app answered.
  Future<Map<String, dynamic>> toolCall(
      _Harness h, String name, Map<String, dynamic> args, String id) async {
    h.socket.serverSends({
      'toolCall': {
        'functionCalls': [
          {'id': id, 'name': name, 'args': args},
        ],
      },
    });
    for (var i = 0; i < 200; i++) {
      for (final message in h.socket.sent) {
        final responses = (message['tool_response'] as Map?)?['function_responses'];
        if (responses is List) {
          for (final response in responses.cast<Map>()) {
            if (response['id'] == id) {
              return ((response['response'] as Map)['output'] as Map).cast<String, dynamic>();
            }
          }
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    fail('no tool response for $id');
  }

  group('corrections (EC-07)', () {
    const propose = {
      'action': 'propose',
      'about': 'savings goal',
      'attribute': 'amount',
      'value': '7k',
    };

    test('read back first; applied only after a yes, then the context is rebuilt',
        () async {
      h = _Harness(
        state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
        supabase: _EndingNotebooks(),
        rebuild: const ContextRebuildConfig(minInterval: Duration.zero),
      );
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();

      final readBack = await toolCall(h, 'correct_memory', propose, 'c1');
      expect(readBack['status'], 'read_back');
      expect(readBack['say'],
          'So your savings goal amount is 7000 USD, not 8000 USD. Is that right?');
      expect(h.corrections.proposed.single['change'], {'valueNum': 7000});
      expect(h.corrections.applied, isEmpty, reason: 'nothing changes before a yes');

      final done = await toolCall(h, 'correct_memory', {'action': 'confirm'}, 'c2');
      expect(done['status'], 'done');
      expect(h.corrections.applied, ['c-1']);

      // The old value is still in Gemini's window: rebuilt at the next pause.
      h.socket
        ..serverSends({
          'serverContent': {
            'outputTranscription': {'text': 'Updated.', 'finished': true},
          },
        })
        ..serverSends({
          'serverContent': {'turnComplete': true},
        });
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      await h.waitForSocket(2);
    });

    test('nothing to correct gives Lumen nothing to say about storage', () async {
      h = _Harness(supabase: _EndingNotebooks());
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      final result = await toolCall(h, 'correct_memory',
          {...propose, 'about': 'nothing stored'}, 'c1');
      expect(result['status'], 'not_found');
      expect(result.containsKey('say'), isFalse);
      expect(jsonEncode(result).toLowerCase(), isNot(contains('stored')));
    });

    test('a confirm with nothing pending changes nothing', () async {
      h = _Harness(supabase: _EndingNotebooks());
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      final result = await toolCall(h, 'correct_memory', {'action': 'confirm'}, 'c1');
      expect(result['status'], 'nothing_to_confirm');
      expect(h.corrections.applied, isEmpty);
    });

    test('a rejected read-back asks again, then offers to forget it', () async {
      h = _Harness(supabase: _EndingNotebooks());
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      await toolCall(h, 'correct_memory', propose, 'c1');
      final once = await toolCall(h, 'correct_memory', {'action': 'reject'}, 'c2');
      expect(once['offerRemoval'], isFalse);
      await toolCall(h, 'correct_memory', propose, 'c3');
      final twice = await toolCall(h, 'correct_memory', {'action': 'reject'}, 'c4');
      expect(twice['offerRemoval'], isTrue);
      expect(h.corrections.rejected, ['c-1', 'c-2']);
      expect(h.corrections.applied, isEmpty);
    });

    test('off the record, nothing is corrected', () async {
      h = _Harness(supabase: _EndingNotebooks());
      await openFreshOffTheRecord(h);
      final result = await toolCall(h, 'correct_memory', propose, 'c1');
      expect(result['status'], 'off_the_record');
      expect(h.corrections.proposed, isEmpty);
    });

    test('the disputing turn does not record its own facts', () async {
      h = _Harness(supabase: _EndingNotebooks());
      h.extractor.result = const GraphPatch(
        entities: [EntityPatch(name: 'savings goal', type: EntityType.concept)],
        relations: [],
        supersedes: [],
        facts: [
          FactPatch(entity: 'savings goal', attribute: 'amount', valueNum: 7000,
              unit: 'USD', status: 'confirmed'),
        ],
      );
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      h.socket.serverSends({
        'serverContent': {
          'inputTranscription': {'text': "No, it's 7k, not 8k.", 'finished': true},
        },
      });
      await toolCall(h, 'correct_memory', propose, 'c1');
      h.socket
        ..serverSends({
          'serverContent': {
            'outputTranscription': {'text': 'So 7000, not 8000?', 'finished': true},
          },
        })
        ..serverSends({
          'serverContent': {'turnComplete': true},
        });
      await _waitForCommits(h, 1);
      await _settle();
      expect(h.facts.calls, isEmpty,
          reason: 'the correction, once confirmed, is the record of it');
    });
  });

  group('back on the record', () {
    Map<String, dynamic> context(FakeLiveSocket socket) =>
        socket.sent.firstWhere((m) => m.containsKey('client_content'));

    void lumenSays(FakeLiveSocket socket, String text) => socket
      ..serverSends({
        'serverContent': {
          'outputTranscription': {'text': text, 'finished': true},
        },
      })
      ..serverSends({
        'serverContent': {'turnComplete': true},
      });

    Future<void> saveThenGoOff() async {
      h = _Harness(
        state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
        supabase: _EndingNotebooks(),
      );
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      h.socket.serverSends({
        'sessionResumptionUpdate': {'resumable': true, 'newHandle': 'old'},
      });
      expect(h.journal.sendTypedTurn('Saved words.'), isTrue);
      await _waitForCommits(h, 1);
      h.journal.setOffTheRecord(true);
      userSaysAndLumenReplies(h, 'The secret.', 'About the secret.');
      await _settle();
    }

    test('Gemini starts a new conversation from saved turns only', () async {
      await saveThenGoOff();

      h.journal.setOffTheRecord(false);
      await h.waitForSocket(2);
      expect(h.socket.setup['session_resumption'], isEmpty,
          reason: 'no handle: nothing carried over');

      h.socket.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();

      final sent = jsonEncode(context(h.socket));
      expect(sent, contains('Saved words.'));
      expect(sent, isNot(contains('secret')));
    });

    test("Lumen's turns stay unsaved until that is done", () async {
      await saveThenGoOff();
      final savedBefore = h.transcripts.saved.length;

      h.journal.setOffTheRecord(false);
      await h.waitForSocket(2);
      lumenSays(h.socket, 'Echoing the secret.');
      await _settle();
      expect(h.transcripts.saved.length, savedBefore);
      expect(h.extractor.texts, isNot(contains('Echoing the secret.')));

      h.socket.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();
      lumenSays(h.socket, 'A new reply.');
      await _settle();
      expect(h.transcripts.saved.map((t) => t.text), contains('A new reply.'));
      expect(h.transcripts.saved.map((t) => t.text),
          isNot(contains('Echoing the secret.')));
    });

    test('the new conversation gets a new token', () async {
      await saveThenGoOff();
      final oldToken = h.socket.uri.queryParameters['access_token'];

      h.journal.setOffTheRecord(false);
      await h.waitForSocket(2);
      expect(h.socket.uri.queryParameters['access_token'], isNot(oldToken));
    });

    test('a session not connected has nothing to reopen', () async {
      h = _Harness(
        state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
        supabase: _EndingNotebooks(),
      );
      await h.journal.enterNotebook(_notebookId);
      h.journal.setOffTheRecord(true);
      h.journal.setOffTheRecord(false);
      await _settle();
      expect(h.sockets, isEmpty);
    });
  });

  test('starting again after an error releases the old mic and socket',
      () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
      supabase: _EndingNotebooks(),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    h.socket.serverCloses(); // no resumption handle: the session errors
    await _settle();
    expect(h.container.read(sessionStatusProvider), SessionStatus.error);

    await h.startLive();
    expect(h.mic.stops, 1, reason: 'the old capture is stopped, not orphaned');
    expect(h.mic.starts, 2);
  });

  group('a session in error', () {
    int audioFrames(FakeLiveSocket socket) => socket.audioFrames.length;

    Future<void> openLive() async {
      h = _Harness(
        state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
        supabase: _EndingNotebooks(),
      );
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
    }

    /// Three reconnect attempts, each waiting 8 s for a setup ack that doesn't
    /// come. Returns the last socket, left open.
    Future<FakeLiveSocket> giveUpOnSetupAck() async {
      h.socket
        ..serverSends({
          'sessionResumptionUpdate': {'newHandle': 'h1', 'resumable': true},
        })
        ..serverCloses();
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while (h.container.read(sessionStatusProvider) != SessionStatus.error &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(h.container.read(sessionStatusProvider), SessionStatus.error);
      return h.socket;
    }

    test('goAway with no handle: the mic stops and the socket closes',
        () async {
      await openLive();
      final socket = h.socket;

      socket.serverSends({
        'goAway': {'timeLeft': '30s'},
      });
      await _settle();

      expect(h.container.read(sessionStatusProvider), SessionStatus.error);
      expect(h.mic.recording, isFalse, reason: 'the dock shows idle');
      expect(h.mic.stops, 1);
      expect(socket.sinkImpl.closed, isTrue);

      final frames = audioFrames(socket);
      h.mic.speak(1);
      await _settle();
      expect(audioFrames(socket), frames);
    });

    test('nothing that arrives after the goAway is saved', () async {
      await openLive();
      final commits = h.commits.commits;

      h.socket
        ..serverSends({
          'goAway': {'timeLeft': '30s'},
        })
        ..serverSends({
          'serverContent': {
            'inputTranscription': {
              'text': 'After the error.',
              'finished': true
            },
          },
        })
        ..serverSends({
          'serverContent': {
            'outputTranscription': {'text': 'A late reply.', 'finished': true},
          },
        })
        ..serverSends({
          'serverContent': {'turnComplete': true},
        });
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(h.transcripts.saved, isEmpty);
      expect(h.commits.commits, commits);
    });

    test('a frame already on its way as the session fails is dropped',
        () async {
      await openLive();
      final socket = h.socket;
      final frames = audioFrames(socket);
      h.mic.onStop = () => h.mic.speak(1);

      socket.serverSends({
        'goAway': {'timeLeft': '30s'},
      });
      await _settle();

      expect(h.mic.stops, 1);
      expect(audioFrames(socket), frames);
    });

    test('a setup ack arriving after giving up sends nothing', () async {
      await openLive();
      final last = await giveUpOnSetupAck();
      await _settle();
      expect(h.mic.recording, isFalse);

      h.mic.speak(1);
      last.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();
      h.mic.speak(2);
      await _settle();

      expect(audioFrames(last), 0);
      expect(h.container.read(sessionStatusProvider), SessionStatus.error);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('no connection opens by itself after giving up', () async {
      await openLive();
      final last = await giveUpOnSetupAck();
      final sockets = h.sockets.length;

      last.serverCloses(); // the stalled socket finally dies
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(h.sockets.length, sockets);
      expect(h.container.read(sessionStatusProvider), SessionStatus.error);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a tap after giving up starts cleanly', () async {
      await openLive();
      final last = await giveUpOnSetupAck();
      await _settle();

      await h.startLive();
      await _settle();

      expect(identical(h.socket, last), isFalse);
      expect(h.mic.recording, isTrue);
      expect(h.container.read(sessionStatusProvider), SessionStatus.live);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  test('the only caller of redaction is the card pipeline', () {
    // redact_forgotten_text runs inside close-session, so no card call in the
    // tests above means no redaction call. Nothing on the device reaches it.
    final callers = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => f.readAsStringSync().contains('redact_forgotten'));
    expect(callers, isEmpty);
  });

  test('a new notebook can open without Lumen, and stays off the record',
      () async {
    final notebooks = _EndingNotebooks();
    h = _Harness(supabase: notebooks);

    final entered = await h.journal.enterNotebook(
      _notebookId,
      offTheRecord: true,
      beforeOpening: () async => false,
    );
    await _settle();

    expect(entered.succeeded, isTrue);
    expect(h.sockets, isEmpty, reason: 'no session started');
    expect(h.mic.starts, 0);
    expect(h.journal.offTheRecord, isTrue);

    final left = await h.journal.leaveNotebook();
    await _settle();
    expect(left.nothingSaved, isTrue);
    expect(notebooks.deleted, [_notebookId]);
    _expectNoWrites(h);
  });

  test('an old notebook visited off the record is left as it was', () async {
    final notebooks = _EndingNotebooks();
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
      history: const [_oldNotebook],
      supabase: notebooks,
    );
    await h.journal.enterNotebook(_notebookId);
    h.journal.setOffTheRecord(true);
    await h.startLive();
    expect(h.journal.sendTypedTurn('Off the record.'), isTrue);
    await _settle();

    final left = await h.journal.leaveNotebook();
    await _settle();

    expect(left.nothingSaved, isTrue);
    expect(notebooks.deleted, isEmpty, reason: 'earlier sessions stay');
    expect(notebooks.ended, isEmpty);
    _expectNoWrites(h);
  });

  test('going off the record mid-session keeps what was saved before',
      () async {
    final notebooks = _EndingNotebooks();
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
      supabase: notebooks,
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    expect(h.journal.sendTypedTurn('Saved before the switch.'), isTrue);
    await _waitForCommits(h, 1);
    expect(h.commits.commits, 1);
    expect(h.cards.drafted, [_notebookId]);

    h.journal.setOffTheRecord(true);
    expect(h.journal.hasSavedTurns, isTrue);
    expect(h.journal.sendTypedTurn('Never saved.'), isTrue);
    userSaysAndLumenReplies(h, 'Nor this.', 'Nor that.');
    await _settle();

    expect(h.commits.commits, 1);
    expect(h.extractor.texts, ['Saved before the switch.']);
    expect(
        h.transcripts.saved.map((t) => t.text), ['Saved before the switch.']);
    expect(h.journal.conversation.map((t) => t.text),
        ['Saved before the switch.']);
    expect(h.cards.drafted, [_notebookId], reason: 'no draft once it is on');

    final left = await h.journal.leaveNotebook();
    await _settle();

    // Card and brief come from what was saved.
    expect(left.nothingSaved, isFalse);
    expect(notebooks.ended, [_notebookId]);
    expect(notebooks.deleted, isEmpty);
    expect(h.cards.closed, [_notebookId]);
    expect(h.briefs.requested, [_notebookId]);
    expect(h.commits.commits, 1);
  });

  test('turning it back off resumes saving; the gap stays unsaved', () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
      supabase: _EndingNotebooks(),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    expect(h.journal.sendTypedTurn('First, saved.'), isTrue);
    await _waitForCommits(h, 1);
    h.journal.setOffTheRecord(true);
    expect(h.journal.sendTypedTurn('Second, secret.'), isTrue);
    await _settle();
    h.journal.setOffTheRecord(false);
    expect(h.journal.offTheRecord, isFalse);
    expect(h.journal.sendTypedTurn('Third, saved.'), isTrue);
    await _waitForCommits(h, 2);
    await _settle();

    expect(h.commits.commits, 2);
    expect(h.extractor.texts, ['First, saved.', 'Third, saved.']);
    expect(h.transcripts.saved.map((t) => t.text),
        ['First, saved.', 'Third, saved.']);
    // The secret turn is on screen, in order, but nowhere else.
    expect(
        [for (final row in h.journal.transcriptRows) row.turn.text],
        containsAllInOrder(
            ['First, saved.', 'Second, secret.', 'Third, saved.']));
  });

  test(
      "a later extraction's recent conversation leaves out off-the-record turns",
      () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
      supabase: _EndingNotebooks(),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    expect(h.journal.sendTypedTurn('Before.'), isTrue);
    await _waitForCommits(h, 1);
    h.journal.setOffTheRecord(true);
    expect(h.journal.sendTypedTurn('Secret about Priya.'), isTrue);
    await _settle();
    h.journal.setOffTheRecord(false);
    expect(h.journal.sendTypedTurn('After.'), isTrue);
    await _waitForCommits(h, 2);

    expect(h.extractor.texts, ['Before.', 'After.']);
    for (final context in h.extractor.contexts) {
      expect(context.join(' '), isNot(contains('Priya')));
    }
    expect(h.extractor.contexts.last, ['Before.', 'After.']);
  });

  test('a turn begun off the record stays off if the switch is turned back off',
      () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
      supabase: _EndingNotebooks(),
    );
    await h.journal.enterNotebook(_notebookId);
    h.journal.setOffTheRecord(true);
    await h.startLive();

    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'Half a secret'},
      },
    });
    await _settle();
    h.journal.setOffTheRecord(false);
    h.socket
      ..serverSends({
        'serverContent': {
          'inputTranscription': {
            'text': 'Half a secret, done.',
            'finished': true
          },
        },
      })
      ..serverSends({
        'serverContent': {'turnComplete': true},
      });
    await _settle();

    expect(h.commits.commits, 0);
    expect(h.extractor.texts, isEmpty);
    expect(h.transcripts.saved, isEmpty);
  });

  test(
      'an off-the-record session does not consume the brief when no opener plays',
      () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
      history: const [_oldNotebook],
      supabase: _EndingNotebooks(),
    );
    final brief = SessionBrief(
      focus: const ['Maya'],
      openingThread: 'the move',
      openingLine: 'Welcome back.',
      createdAt: _recentBrief,
      playedAt: null,
      pcm: Uint8List(24000),
      sampleRate: 24000,
    );
    h.briefs.state = SessionOpeningState(returning: true, brief: brief);
    await h.prep.refresh();

    await h.journal.enterNotebook(_notebookId, offTheRecord: true);
    await h.startLive();
    await h.journal.leaveNotebook();
    await _settle();

    expect(h.briefs.played, isEmpty);
    expect(h.prep.current!.brief!.playedAt, isNull);
    expect(h.briefs.requested, isEmpty);
  });

  test('an opener that does play marks its brief played, off the record too',
      () async {
    h = _Harness(supabase: _EndingNotebooks());
    final brief = SessionBrief(
      focus: const ['Maya'],
      openingThread: 'the move',
      openingLine: 'Welcome back.',
      createdAt: _recentBrief,
      playedAt: null,
      pcm: Uint8List(24000),
      sampleRate: 24000,
    );
    h.briefs.state = SessionOpeningState(returning: true, brief: brief);
    await h.prep.refresh();

    await openFreshOffTheRecord(h);
    await _settle();

    expect(h.briefs.played, [brief.createdAt]);
    await h.journal.leaveNotebook();
    expect(h.briefs.requested, isEmpty, reason: 'no new brief is written');
  });

  test('a turn begun on the record but finalized after the switch is not saved',
      () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
      supabase: _EndingNotebooks(),
    );
    await h.journal.enterNotebook(_notebookId);
    await h.startLive();

    // The user is mid-sentence on the record...
    h.socket.serverSends({
      'serverContent': {
        'inputTranscription': {'text': 'I was saying'},
      },
    });
    await _settle();
    // ...the switch goes on, then the sentence finalizes.
    h.journal.setOffTheRecord(true);
    h.socket
      ..serverSends({
        'serverContent': {
          'inputTranscription': {
            'text': 'I was saying something private.',
            'finished': true,
          },
        },
      })
      ..serverSends({
        'serverContent': {'turnComplete': true},
      });
    await _settle();

    expect(h.commits.commits, 0);
    expect(h.extractor.texts, isEmpty);
    expect(h.transcripts.saved, isEmpty);
    expect(h.journal_.writes, 0);
    expect(
      [for (final row in h.journal.transcriptRows) row.turn.text],
      contains(contains('something private.')),
    );
  });

  test('a failed delete does not stop leaving', () async {
    final notebooks = _EndingNotebooks()..deleteFails = StateError('offline');
    h = _Harness(supabase: notebooks);
    await openFreshOffTheRecord(h);

    final left = await h.journal.leaveNotebook();

    expect(left.succeeded, isTrue);
    expect(left.nothingSaved, isTrue);
    expect(notebooks.deleted, [_notebookId]);
  });

  test('turning it off while not live does not restart card drafting',
      () async {
    h = _Harness(
      state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
      supabase: _EndingNotebooks(),
    );
    await h.journal.enterNotebook(_notebookId);
    h.journal.setOffTheRecord(true);
    h.journal.setOffTheRecord(false);
    await h.startLive();
    expect(h.journal.sendTypedTurn('Saved.'), isTrue);
    await _waitForCommits(h, 1);
    expect(h.cards.drafted, [_notebookId], reason: 'drafting works once live');
  });

  group('context rebuild (EC-01)', () {
    const twoTurns = ContextRebuildConfig(
      maxTurns: 2,
      minInterval: Duration.zero,
    );
    // Past the provider's 800 ms grace after Lumen's turn ends.
    Future<void> pastRebuildCheck() =>
        Future<void>.delayed(const Duration(milliseconds: 1000));

    Future<void> liveInSavedNotebook(ContextRebuildConfig? rebuild) async {
      h = _Harness(
        state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
        supabase: _EndingNotebooks(),
        rebuild: rebuild,
      );
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      h.socket.serverSends({
        'sessionResumptionUpdate': {'resumable': true, 'newHandle': 'old'},
      });
      await _settle();
    }

    test('a spent turn budget rebuilds at a pause from saved context',
        () async {
      await liveInSavedNotebook(twoTurns);
      userSaysAndLumenReplies(h, 'My goal is 350 now.', 'Noted.');
      await _waitForCommits(h, 1);
      await pastRebuildCheck();
      expect(h.sockets, hasLength(1), reason: 'one turn: budget not spent');

      userSaysAndLumenReplies(h, 'And Maya starts Monday.', 'Lovely.');
      await pastRebuildCheck();
      await h.waitForSocket(2);
      expect(h.socket.setup['session_resumption'], isEmpty,
          reason: 'a new conversation, seeded by the app, not resumed');
      expect(h.journal.reconnecting, isFalse,
          reason: 'a planned rebuild shows no "Reconnecting" chip');

      h.socket.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();
      final seeded = jsonEncode(
        h.socket.sent.firstWhere((m) => m.containsKey('client_content')),
      );
      expect(seeded, contains('My goal is 350 now.'));
      expect(seeded, contains('And Maya starts Monday.'));
      expect(h.tokensMinted, greaterThanOrEqualTo(2),
          reason: 'a new conversation takes a new single-use token');
    });

    test('a rebuilt context lists topics already raised and the latest lines',
        () async {
      h = _Harness(
        state: JournalState.empty().copyWith(
          entries: [_entry('Earlier.')],
          entities: {
            'priya': Entity(
              id: 'priya',
              name: 'Priya',
              type: EntityType.person,
              metadata: const {},
              mentions: 1,
              firstSeen: DateTime(2026, 11, 21),
              lastSeen: DateTime(2026, 11, 21),
            ),
            'samsung': Entity(
              id: 'samsung',
              name: 'Samsung',
              type: EntityType.organization,
              metadata: const {},
              mentions: 1,
              firstSeen: DateTime(2026, 11, 21),
              lastSeen: DateTime(2026, 11, 21),
            ),
          },
        ),
        supabase: _EndingNotebooks(),
        rebuild: const ContextRebuildConfig(
          maxTurns: 10,
          minInterval: Duration.zero,
        ),
      );
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      userSaysAndLumenReplies(h, 'Hi.', "How's Priya doing?");
      await _settle();
      for (var i = 1; i < 10; i++) {
        userSaysAndLumenReplies(h, 'Turn $i.', 'Question $i?');
        await _settle();
      }
      await pastRebuildCheck();
      await h.waitForSocket(2);
      h.socket.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();

      final content = h.socket.sent
          .firstWhere((m) => m.containsKey('client_content'))['client_content']
          as Map<String, dynamic>;
      final summaryLine = [
        for (final turn in content['turns'] as List)
          for (final part in (turn as Map)['parts'] as List)
            ...((part as Map)['text'] as String).split('\n'),
      ].firstWhere((line) => line.startsWith('[graph summary] '));
      final summary = jsonDecode(
          summaryLine.substring('[graph summary] '.length)) as Map<String, dynamic>;
      expect(summary['probedThisSession'], ['Priya'],
          reason: 'Lumen raised Priya in its first reply, before the last 16 '
              'turns the live conversation keeps; Samsung never came up');
      expect(summary['recentAgentQuestions'],
          [for (var i = 2; i < 10; i++) 'Question $i?'],
          reason: 'the latest eight, not the first eight');
    });

    test('a rebuilt context carries the open question, paused topic, promise '
        'and register (EC-04)', () async {
      await liveInSavedNotebook(twoTurns);
      userSaysAndLumenReplies(
          h, 'Priya is moving to Lisbon.', 'How do you feel about her move?');
      await _settle();
      userSaysAndLumenReplies(h, "Honestly I'm stressed. Not now.",
          "Okay. I'll ask you about it tomorrow. What else is on your mind?");
      await pastRebuildCheck();
      await h.waitForSocket(2);
      h.socket.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();

      final content = h.socket.sent
          .firstWhere((m) => m.containsKey('client_content'))['client_content']
          as Map<String, dynamic>;
      final summaryLine = [
        for (final turn in content['turns'] as List)
          for (final part in (turn as Map)['parts'] as List)
            ...((part as Map)['text'] as String).split('\n'),
      ].firstWhere((line) => line.startsWith('[graph summary] '));
      final state = (jsonDecode(summaryLine.substring('[graph summary] '.length))
          as Map<String, dynamic>)['sessionState'] as Map<String, dynamic>;
      expect(state['openThreads'], ['What else is on your mind?']);
      expect(state['pausedTopics'], ['How do you feel about her move?']);
      expect(state['commitments'], ["I'll ask you about it tomorrow."]);
      expect(state['register'], 'stressed');
    });

    test('the session state is saved on the record and cleared at the end '
        '(EC-04)', () async {
      await liveInSavedNotebook(null);
      userSaysAndLumenReplies(h, "I'm tired today.", 'What wore you out?');
      await _settle();
      expect(h.sessionState.saved, isNotEmpty);
      expect(h.sessionState.saved.last['openThreads'], ['What wore you out?']);
      expect(h.sessionState.saved.last['register'], 'tired');

      await h.journal.leaveNotebook();
      expect(h.sessionState.cleared, [_notebookId]);
    });

    test('a conversation reopened after a restart picks up its saved state '
        '(EC-04)', () async {
      h = _Harness(
        state: JournalState.empty().copyWith(entries: [_entry('Earlier.')]),
        supabase: _EndingNotebooks(),
        rebuild: twoTurns,
      );
      h.sessionState.stored = {
        'openThreads': ['How did the interview go?'],
        'pausedTopics': <String>[],
        'asked': ['How did the interview go?'],
        'commitments': <String>[],
        'register': null,
        'covered': <String>[],
      };
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      await _settle();
      userSaysAndLumenReplies(h, 'Hmm.', 'Take your time.');
      await _settle();
      expect(h.sessionState.saved.last['openThreads'], ['How did the interview go?'],
          reason: 'a filler reply does not answer the question it was asked');
    });

    test('a rebuild continues from the materialised context (EC-05)', () async {
      h = _Harness(
        state: JournalState.empty().copyWith(
          entries: [_entry('Earlier.')],
          entities: {
            'savings-goal': Entity(
              id: 'savings-goal',
              name: 'savings goal',
              type: EntityType.concept,
              metadata: const {},
              mentions: 2,
              firstSeen: DateTime(2026, 11, 20),
              lastSeen: DateTime(2026, 11, 21),
            ),
          },
        ),
        supabase: _EndingNotebooks(),
        rebuild: const ContextRebuildConfig(maxTurns: 8, minInterval: Duration.zero),
      );
      h.facts.current = const [
        WorkingFact(entityId: 'savings-goal', attribute: 'amount', valueNum: 8000,
            unit: 'USD', status: 'confirmed'),
      ];
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      for (var i = 0; i < 8; i++) {
        userSaysAndLumenReplies(h, 'User line $i.', 'Lumen line $i?');
        await _settle();
      }
      await pastRebuildCheck();
      await h.waitForSocket(2);
      h.socket.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();

      final content = h.socket.sent
          .firstWhere((m) => m.containsKey('client_content'))['client_content']
          as Map<String, dynamic>;
      final texts = [
        for (final turn in content['turns'] as List)
          for (final part in (turn as Map)['parts'] as List) (part as Map)['text'] as String,
      ];
      expect(texts.first, startsWith('[continuation] '));
      expect(texts.join('\n'), isNot(contains('[opening said]')));
      final summary = jsonDecode(texts.first
              .split('\n')
              .firstWhere((l) => l.startsWith('[graph summary] '))
              .substring('[graph summary] '.length)) as Map<String, dynamic>;
      final goal = (summary['workingSet'] as List)
          .firstWhere((row) => (row as Map)['name'] == 'savings goal') as Map;
      expect(goal['facts'], ['amount: 8000 USD']);
      // The context, six recent turns and the resume note: not a 20-turn replay.
      expect(texts.length, 1 + 6 + 1);
      expect(texts[texts.length - 2], 'Lumen line 7?');
      expect(texts.contains('User line 0.'), isFalse);
    });

    test('typed turns with the mic paused still rebuild at a pause', () async {
      // Found in the Simulator: opening the composer pauses the mic, and a
      // typed-only conversation never rebuilt.
      await liveInSavedNotebook(twoTurns);
      await h.journal.pauseMic();
      for (final text in ['Typed one.', 'Typed two.']) {
        expect(h.journal.sendTypedTurn(text), isTrue);
        h.socket
          ..serverSends({
            'serverContent': {
              'outputTranscription': {'text': 'Reply.', 'finished': true},
            },
          })
          ..serverSends({
            'serverContent': {'turnComplete': true},
          });
        await _settle();
      }
      await pastRebuildCheck();
      await h.waitForSocket(2);
      h.socket.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();
      expect(
        jsonEncode(
            h.socket.sent.firstWhere((m) => m.containsKey('client_content'))),
        contains('Typed two.'),
      );
    });

    test('without the flag the session is never rebuilt', () async {
      await liveInSavedNotebook(null);
      for (var i = 0; i < 3; i++) {
        userSaysAndLumenReplies(h, 'Turn $i.', 'Reply $i.');
        await _settle();
      }
      await pastRebuildCheck();
      expect(h.sockets, hasLength(1));
    });

    test('off the record never rebuilds: its turns are not saved', () async {
      await liveInSavedNotebook(twoTurns);
      h.journal.setOffTheRecord(true);
      for (var i = 0; i < 3; i++) {
        userSaysAndLumenReplies(h, 'Secret $i.', 'Reply $i.');
        await _settle();
      }
      await pastRebuildCheck();
      expect(h.sockets, hasLength(1));
    });

    test('the production client compresses only when not rebuilding', () {
      GeminiLiveClient make(ContextRebuildConfig? rebuild) {
        final container = ProviderContainer(overrides: [
          contextRebuildConfigProvider.overrideWithValue(rebuild),
        ]);
        addTearDown(container.dispose);
        return container.read(liveClientFactoryProvider)(
          sessionToken: 't',
          model: 'm',
        );
      }

      expect(make(null).compressContext, isTrue);
      expect(make(twoTurns).compressContext, isFalse);
      // h is torn down after every test; give this one a harness too.
      h = _Harness();
    });
  });
}

// Recent at run time: a brief over sessionBriefMaxAge (21 days) is stale.
final _recentBrief = DateTime.utc(
  DateTime.now().year, DateTime.now().month, DateTime.now().day,
).subtract(const Duration(days: 1));
