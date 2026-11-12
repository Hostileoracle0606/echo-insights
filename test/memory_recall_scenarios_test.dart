// Cross-feature recall scenarios (forget, auto-forget, name swap) over the harness of
// journal_session_lifecycle_test.dart, copied because its fakes are private. Real
// JournalNotifier and GeminiLiveClient; the socket, mic, speaker and network are fakes.
// (original header: end to end through the real
// JournalNotifier and GeminiLiveClient: only the socket, the microphone, the
// speaker and the token source are fakes.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/audio/pcm_capture.dart';
import 'package:lumen/audio/pcm_player.dart';
import 'package:lumen/logic/turn_state.dart' hide CommitCommitted;
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
import 'package:lumen/services/memory_control_service.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';
import 'package:lumen/logic/slugify.dart';
import 'package:lumen/logic/merge.dart' as merge_logic;
import 'package:lumen/models/entity.dart';
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
const _otherNotebookId = '5c1d2a9e-7b3f-4e8a-9d61-0f2b7c4e8a13';

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
  JournalState state;
  bool failSnapshots = false;
  int commits = 0;

  @override
  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async {
    if (failSnapshots) throw StateError('offline');
    return NotebookSnapshot(notebookId: notebookId, revision: 3, state: state);
  }

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
  final recent = <String>[];

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
    recent.addAll(recentConversation.map((t) => t.text));
    return GraphPatch.empty();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoMemory implements RetrieveMemoryService {
  final queries = <String>[];

  @override
  Future<MemoryRetrieval> retrieveResult({
    required String query,
    required String notebookId,
    JournalState? state,
    RetrievalScope scope = RetrievalScope.notebook,
    Duration? timeout,
  }) async {
    queries.add(query);
    return MemoryRetrieval.empty;
  }

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

class _FakeMemory implements MemoryControlService {
  final forgotten = <String>[];
  @override
  Future<ForgetPreview> forgetEntity(String entityId) async {
    forgotten.add(entityId);
    return const ForgetPreview(
        notebooks: 2, relations: 1, followUps: 1, askedQuestions: 1, cards: 2, briefDeleted: true);
  }

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
      retrieveMemoryServiceProvider.overrideWithValue(retrievals),
      turnJournalServiceProvider.overrideWithValue(_FakeTurnJournal()),
      transcriptStoreProvider.overrideWithValue(transcripts),
      openingTimeoutProvider.overrideWithValue(openingTimeout),
      supabaseServiceProvider
          .overrideWithValue(supabase ?? _NoNotebookInserts()),
      sessionCardServiceProvider.overrideWithValue(cards),
      sessionBriefServiceProvider.overrideWithValue(briefs),
      memoryControlServiceProvider.overrideWithValue(memory),
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
  final retrievals = _NoMemory();
  final cards = _FakeCards();
  final briefs = _FakeBriefs();
  final memory = _FakeMemory();
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

/// The texts of the one context message sent before Lumen's first reply.
List<Object?> _contextTexts(FakeLiveSocket socket) {
  final context = socket.sent
      .map((m) => m['client_content'])
      .whereType<Map<String, dynamic>>()
      .single;
  expect(context['turn_complete'], isFalse);
  return [
    for (final turn in context['turns'] as List)
      (((turn as Map)['parts'] as List).single as Map)['text'],
  ];
}

/// The words of a bundled clip, as the app reads them.
String _bundledText(String name) =>
    File('assets/audio/$name.txt').readAsStringSync().trim();

JournalEntry _entry(String text) => JournalEntry(
      id: 'entry-1',
      text: text,
      createdAt: DateTime.utc(2026, 9, 20, 12),
      entityIds: const [],
      relationIds: const [],
    );

final _t0 = DateTime.utc(2026, 11, 1);

Entity _ent(String id, String name, EntityType type,
        {String? description, List<String>? questions, int mentions = 1}) =>
    Entity(
      id: id,
      name: name,
      type: type,
      description: description,
      metadata: const {},
      mentions: mentions,
      firstSeen: _t0,
      lastSeen: _t0,
      questions: questions,
    );

JournalState _stateOf(List<Entity> entities, {List<JournalEntry> entries = const []}) =>
    JournalState.empty().copyWith(
      entities: {for (final e in entities) e.id: e},
      entries: entries,
    );

SessionBrief _briefAbout(String line, List<String> focus, String thread) =>
    SessionBrief(
      focus: focus,
      openingThread: thread,
      openingLine: line,
      createdAt: DateTime.utc(2026, 11, 7, 9),
      playedAt: null,
      pcm: Uint8List(24000),
      sampleRate: 24000,
    );

final _priyaBrief = _briefAbout(
    'Hi again. How is Priya Raman\'s leg?',
    const ['Priya Raman', 'Halvorsen Group'],
    'Priya Raman\'s stress fracture');
final _halvorsenBrief = _briefAbout(
    'Hi. How is work at Halvorsen Group?', const ['work'], 'work at Halvorsen Group');

// Graph as the server holds it before the forget, and as it returns it after.
JournalState _beforeForget() => _stateOf([
      _ent('priya-raman', 'Priya Raman', EntityType.person,
          description: 'My sister. Stress fracture'),
      _ent('halvorsen-group', 'Halvorsen Group', EntityType.organization,
          description: 'Where I work'),
      _ent('city-marathon', 'City Marathon', EntityType.event,
          description: 'Priya Raman\'s first marathon',
          questions: ['How is Priya Raman\'s training going?']),
      _ent('priya-nair', 'Priya Nair', EntityType.person,
          description: 'Colleague at Halvorsen Group'),
    ], entries: [
      _entry('Priya Raman has a stress fracture. Priya Nair is at Halvorsen Group.')
    ]);

JournalState _afterForget({bool entriesRedacted = false}) => _stateOf([
      _ent('halvorsen-group', 'Halvorsen Group', EntityType.organization,
          description: 'Where I work'),
      _ent('city-marathon', 'City Marathon', EntityType.event,
          description: 'someone\'s first marathon',
          questions: ['How is someone\'s training going?']),
      _ent('priya-nair', 'Priya Nair', EntityType.person,
          description: 'Colleague at Halvorsen Group'),
    ], entries: [
      _entry(entriesRedacted
          ? 'someone has a stress fracture. Priya Nair is at Halvorsen Group.'
          : 'Priya Raman has a stress fracture. Priya Nair is at Halvorsen Group.')
    ]);

ConversationTurn _turn(String id, Speaker role, String text, {String? contextText}) =>
    ConversationTurn(
      turnId: id,
      role: role,
      text: text,
      createdAt: '2026-11-05T10:00:0${id.length % 10}Z',
      contextText: contextText,
    );

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void _userSays(FakeLiveSocket socket, String text) => socket
  ..serverSends({
    'serverContent': {
      'inputTranscription': {'text': text, 'finished': true},
    },
  })
  ..serverSends({
    'serverContent': {'turnComplete': true},
  });

Future<String> _newSessionContext(_Harness h, {String id = _notebookId}) async {
  final entering = h.journal.enterNotebook(id);
  await h.waitForSocket(h.sockets.length + 1);
  h.socket.serverSends({'setupComplete': <String, dynamic>{}});
  expect((await entering).succeeded, isTrue);
  return _contextTexts(h.socket).first as String;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;
  tearDown(() => h.dispose());

  group('opening a new session', () {
    test('after auto-forget the brief and graph survive: the opening still carries them',
        () async {
      h = _Harness(); // S3's own snapshot is empty, as the server returns it
      h.briefs.state = SessionOpeningState(returning: true, brief: _priyaBrief);
      await h.prep.refresh();
      final context = await _newSessionContext(h);
      expect(context, contains('[opening said] "Hi again. How is Priya Raman\'s leg?"'));
      expect(context, contains('"focus":["Priya Raman","Halvorsen Group"]'));
      expect(context.split('\n').last, startsWith('[graph summary] '));
    });

    test('after forget the deleted brief is not spoken or sent; the fallback opens',
        () async {
      h = _Harness(state: _beforeForget());
      h.briefs.state = SessionOpeningState(returning: true, brief: _priyaBrief);
      await h.prep.refresh();
      await h.journal.enterNotebook(_otherNotebookId);
      // The server deleted the brief and redacted the graph.
      h.briefs.state = const SessionOpeningState(returning: true, brief: null);
      h.commits.state = _afterForget();
      await h.journal.forgetEntity('priya-raman');
      expect(h.memory.forgotten, ['priya-raman']);
      expect(h.prep.current!.brief, isNull);
      await h.journal.leaveNotebook();

      h.commits.state = JournalState.empty();
      final context = await _newSessionContext(h);
      expect(context.toLowerCase(), isNot(contains('raman')));
      expect(context, isNot(contains('[session brief]')));
      expect(context, startsWith('[opening said] "${_bundledText('lumen_returning')}"'));
      expect(
        h.journal.transcriptRows.map((r) => r.turn.text).join(' ').toLowerCase(),
        isNot(contains('raman')),
      );
    });

    test('if the brief cannot be reloaded after a forget, the held copy is dropped',
        () async {
      h = _Harness(state: _beforeForget());
      h.briefs.state = SessionOpeningState(returning: true, brief: _priyaBrief);
      await h.prep.refresh();
      await h.journal.enterNotebook(_otherNotebookId);
      h.briefs.state = null; // load() throws
      h.commits.state = _afterForget();
      await h.journal.forgetEntity('priya-raman');
      expect(h.prep.current!.brief, isNull);
      expect(h.prep.current!.returning, isTrue);
      await h.journal.leaveNotebook();

      h.commits.state = JournalState.empty();
      final context = await _newSessionContext(h);
      expect(context.toLowerCase(), isNot(contains('raman')));
    });

    test('after forget, a new brief about surviving memory opens the session',
        () async {
      h = _Harness();
      h.briefs.state = SessionOpeningState(returning: true, brief: _halvorsenBrief);
      await h.prep.refresh();
      final context = await _newSessionContext(h);
      expect(context, contains('[opening said] "Hi. How is work at Halvorsen Group?"'));
      expect(context, contains('"openingThread":"work at Halvorsen Group"'));
      expect(context.toLowerCase(), isNot(contains('raman')));
    });

    test('a reopened notebook\'s graph summary keeps surviving memory and drops her',
        () async {
      h = _Harness(state: _beforeForget());
      await h.journal.enterNotebook(_notebookId);
      h.commits.state = _afterForget();
      await h.journal.forgetEntity('priya-raman');
      await h.startLive();
      final summary = (_contextTexts(h.socket).first as String);
      expect(summary, startsWith('[graph summary] '));
      expect(summary, contains('Halvorsen Group'));
      expect(summary, contains('Priya Nair'));
      expect(summary, contains('How is someone\'s training going?'));
      expect(summary.toLowerCase(), isNot(contains('raman')));
    });

    test('forget with the snapshot reload failing still leaves her out of the summary',
        () async {
      h = _Harness(state: _beforeForget());
      await h.journal.enterNotebook(_notebookId);
      h.commits.failSnapshots = true; // the RPC worked, the reload did not
      await h.journal.forgetEntity('priya-raman');
      await h.startLive();
      final summary = (_contextTexts(h.socket).first as String);
      expect(summary.toLowerCase(), isNot(contains('raman')));
      expect(summary, contains('How is someone\'s training going?'),
          reason: 'redacted at the forget, as the server does (LM-63)');
      expect(summary, contains('Priya Nair'));
    });

    // The fake mirrors the server, which since LM-63 returns each entry's
    // context_text (see memory_recall_scenarios_test.sql, BUG-2).
    test('resume context after forget does not repeat her name', () async {
      h = _Harness(state: _afterForget(entriesRedacted: true));
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      final texts = _contextTexts(h.socket).map((t) => '$t').join('\n');
      expect(texts.toLowerCase(), isNot(contains('raman')));
      expect(texts, contains('someone has a stress fracture'));
    });
  });

  group('name swap (LM-55) across sessions', () {
    // S1's people are in the graph; S2 mentions them again.
    final s1 = _stateOf([
      _ent('priya-raman', 'Priya Raman', EntityType.person, description: 'My sister'),
      _ent('halvorsen-group', 'Halvorsen Group', EntityType.organization,
          description: 'Where I work'),
    ]);
    const utterance = 'Priya Raman has a stress fracture. Work at Halvorsen Group is busy.';

    PseudonymMap mapFor(JournalState s) => PseudonymMap(ownerId: 'u1')
      ..sync([
        for (final e in s.entities.values)
          if (PseudonymEntity.fromEntity(e) != null) PseudonymEntity.fromEntity(e)!,
      ], allNames: [for (final e in s.entities.values) e.name]);

    test('the extraction context recalls S1\'s people, the swap hides them, and the committed ids are real slugs',
        () {
      final context = compileExtractionContext(
        transcript: utterance,
        state: s1,
        retrievedEntityIds: const ['halvorsen-group'],
        recentTurns: const [],
      );
      expect(context.entities.map((e) => e.id), contains('priya-raman'));
      expect(context.entities.map((e) => e.id), contains('halvorsen-group'));

      final message = buildExtractionUserMessage(utterance, context);
      final map = mapFor(s1);
      final sent = map.dehydrate(message);
      expect(sent.roundTripOk, isTrue);
      expect(sent.text, isNot(contains('Priya')));
      expect(sent.text, isNot(contains('Raman')));
      expect(sent.text, isNot(contains('Halvorsen')));

      // A model that reuses the (fake) spellings it was given.
      final fakePerson = map.dehydrate('Priya Raman').text;
      final fakeOrg = map.dehydrate('Halvorsen Group').text;
      expect(slugify(fakePerson), isNot('priya-raman'));
      final modelPatch = {
        'entities': [
          {'name': fakePerson, 'type': 'person', 'description': 'Has a stress fracture'},
          {'name': fakeOrg, 'type': 'organization'},
        ],
        'relations': [
          {'source': fakePerson, 'target': fakeOrg, 'label': 'works_at'},
        ],
        'supersedes': <String>[],
      };
      final restored = jsonDecode(jsonEncode(map.rehydrateJson(modelPatch))) as Map<String, dynamic>;
      final patch = GraphPatch.fromJson(restored);
      final merged = merge_logic.merge(s1, utterance, patch);

      final change = merged.change.toJson();
      final committedIds = [for (final e in change['entities'] as List) (e as Map)['id']];
      expect(committedIds, containsAll(['priya-raman', 'halvorsen-group']));
      expect(merged.next.entities['priya-raman']!.mentions, 2,
          reason: 'S2 adds to S1\'s Priya, it does not create a second one');
      expect(merged.next.entities.length, 2, reason: 'no duplicate entities');
      final wire = change.toString();
      expect(wire, isNot(contains(fakePerson)));
      expect(wire, isNot(contains(fakeOrg)));
      expect(wire, contains('Priya Raman'));
    });

    test('a first-name-only mention still commits to the existing slug when the context lists her',
        () {
      final map = mapFor(s1);
      const text = 'Priya has a stress fracture.';
      final context = compileExtractionContext(
        transcript: text,
        state: s1,
        retrievedEntityIds: const ['priya-raman'],
        recentTurns: const [],
      );
      map.dehydrate(buildExtractionUserMessage(text, context));
      final fake = map.dehydrate('Priya Raman').text;
      final restored = jsonDecode(jsonEncode(map.rehydrateJson({
        'entities': [
          {'name': fake, 'type': 'person'}
        ],
        'relations': <Object>[],
        'supersedes': <String>[],
      }))) as Map<String, dynamic>;
      final merged = merge_logic.merge(s1, text, GraphPatch.fromJson(restored));
      expect(merged.next.entities.keys.toSet(), {'priya-raman', 'halvorsen-group'});
    });

    test('a brand-new notebook\'s extraction context recalls S1\'s people', () {
      // S2 is a new notebook: the server's snapshot of it is empty, and
      // extraction retrieval is notebook-scoped (journal_provider
      // _runDurableExtraction), so S1's people are not in `state`.
      final context = compileExtractionContext(
        transcript: utterance,
        state: JournalState.empty(),
        retrievedEntityIds: const ['priya-raman'],
        recentTurns: const [],
      );
      expect(context.entities.map((e) => e.id), contains('priya-raman'));
    },
        skip: 'FINDING-6: no cross-session entity context reaches extraction in a new '
            'notebook (get_notebook_snapshot is per notebook, retrieval scope is '
            'notebook). A first-name-only mention in S2 creates a separate entity.');

    test('forgetting removes the real name from the stored map, including the reserved word list',
        () {
      final map = mapFor(s1)..dehydrate(utterance);
      map.forget('priya-raman');
      expect(jsonEncode(map.toJson()).toLowerCase(), isNot(contains('raman')));
    });

    test('after forget the swap no longer masks her, and the server drops her on commit', () {
      final map = mapFor(s1)..forget('priya-raman');
      expect(map.dehydrate('Priya Raman called').text, 'Priya Raman called');
      final merged = merge_logic.merge(
        s1.copyWith(entities: {...s1.entities}..remove('priya-raman')),
        'Priya Raman called',
        GraphPatch.fromJson({
          'entities': [
            {'name': 'Priya Raman', 'type': 'person'}
          ],
          'relations': <Object>[],
          'supersedes': <String>[],
        }),
        suppressed: {'priya-raman'},
      );
      expect(merged.next.entities.containsKey('priya-raman'), isFalse,
          reason: 'the device honours the suppression it learned from suppressedIds');
    });
  });

  group('forget everywhere (LM-63)', () {
    test('saved turns reach Lumen as the server redacted them; the transcript keeps the words',
        () async {
      h = _Harness(
        state: _afterForget(entriesRedacted: true),
        history: [
          _turn('t1', Speaker.user, 'Priya Raman has a stress fracture.',
              contextText: 'someone has a stress fracture.'),
          _turn('t2', Speaker.assistant, 'How is Priya Raman now?',
              contextText: 'How is someone now?'),
        ],
      );
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      final sent = jsonEncode(h.socket.sent).toLowerCase();
      expect(sent, isNot(contains('raman')));
      expect(sent, contains('someone has a stress fracture.'));
      expect(
        h.journal.transcriptRows.map((r) => r.turn.text),
        contains('Priya Raman has a stress fracture.'),
        reason: 'the transcript view shows what was said',
      );
    });

    test('a forget mid-session reconnects fresh, seeded without her', () async {
      h = _Harness(
        state: _beforeForget(),
        history: [
          _turn('t1', Speaker.user, 'Priya Raman called about the marathon.'),
          _turn('t2', Speaker.assistant, 'How is Priya Raman feeling?'),
        ],
      );
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      expect(jsonEncode(h.socket.sent), contains('Raman'),
          reason: 'before the forget, the earlier conversation names her');
      final first = h.socket;
      final tokens = h.tokensMinted;

      h.commits.state = _afterForget(entriesRedacted: true);
      await h.journal.forgetEntity('priya-raman');
      await h.waitForSocket(2);
      expect(h.socket, isNot(same(first)));
      expect(h.socket.setup['session_resumption'], isEmpty,
          reason: 'no handle: nothing Gemini heard is carried over');
      expect(h.tokensMinted, greaterThan(tokens), reason: 'a new token');

      h.socket.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();
      final sent = jsonEncode(h.socket.sent);
      expect(sent.toLowerCase(), isNot(contains('raman')));
      expect(sent, contains('someone called about the marathon.'));
      expect(sent, contains('[graph summary]'));
      expect(
        h.journal.transcriptRows.map((r) => r.turn.text),
        contains('Priya Raman called about the marathon.'),
      );
    });

    test('after a forget, extraction and retrieval never carry her name', () async {
      h = _Harness(state: _beforeForget());
      await h.journal.enterNotebook(_notebookId);
      await h.startLive();
      _userSays(h.socket, 'I ran with Priya Raman yesterday.');
      await _settle();
      h.commits.state = _afterForget(entriesRedacted: true);
      await h.journal.forgetEntity('priya-raman');
      await h.waitForSocket(2);
      h.socket.serverSends({'setupComplete': <String, dynamic>{}});
      await _settle();

      _userSays(h.socket, 'PRIYA RAMAN called again, and Priya Nair too.');
      await _settle();
      final afterForget = h.extractor.texts.last;
      expect(afterForget, 'someone called again, and Priya Nair too.');
      expect(h.extractor.recent.last.toLowerCase(), isNot(contains('raman')));
      expect(h.retrievals.queries.last, 'someone called again, and Priya Nair too.');
      expect(h.transcripts.saved.map((t) => t.text),
          contains('PRIYA RAMAN called again, and Priya Nair too.'),
          reason: 'the user\'s own words are saved as said');
    });

    test('the graph drops her duplicate under another id and ids that spell her', () async {
      final state = _beforeForget().copyWith(entities: {
        ..._beforeForget().entities,
        'e-1700000000000': _ent('e-1700000000000', 'Priya Raman', EntityType.person),
        'priya-raman-foundation':
            _ent('priya-raman-foundation', 'Priya Raman Foundation', EntityType.organization),
      });
      h = _Harness(state: state);
      await h.journal.enterNotebook(_notebookId);
      h.commits.failSnapshots = true;
      await h.journal.forgetEntity('priya-raman');
      final ids = h.container.read(journalProvider).entities.keys;
      expect(ids, isNot(contains('e-1700000000000')));
      expect(ids, isNot(contains('priya-raman-foundation')));
      expect(ids, containsAll(['halvorsen-group', 'city-marathon', 'priya-nair']));
      final names = h.container.read(journalProvider).entities.values.map((e) => e.name);
      expect(names.join(' ').toLowerCase(), isNot(contains('raman')));
    });
  });
}
