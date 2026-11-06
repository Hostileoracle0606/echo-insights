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
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/extract_graph_service.dart';
import 'package:lumen/services/extraction_context.dart';
import 'package:lumen/services/gemini_live_client.dart';
import 'package:lumen/services/live_credentials.dart';
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

/// Records what reaches the extraction model.
class _FakeExtractor implements ExtractGraphService {
  final texts = <String>[];
  final contexts = <List<String>>[];

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
    contexts.add([for (final turn in recentConversation) turn.text]);
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
      turnJournalServiceProvider.overrideWithValue(journal_),
      transcriptStoreProvider.overrideWithValue(transcripts),
      openingTimeoutProvider.overrideWithValue(openingTimeout),
      supabaseServiceProvider
          .overrideWithValue(supabase ?? _NoNotebookInserts()),
      sessionCardServiceProvider.overrideWithValue(cards),
      sessionBriefServiceProvider.overrideWithValue(briefs),
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

  final journal_ = _FakeTurnJournal();
  final _FakeTranscripts transcripts;
  final _FakeCommits commits;
  final extractor = _FakeExtractor();
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
      createdAt: DateTime.utc(2026, 10, 27, 9, 30),
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
      createdAt: DateTime.utc(2026, 10, 27, 9, 30),
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
}
