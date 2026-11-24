// One in-memory stand-in for everything a phone talks to during catch-up
// (LM-103 acceptance): commit_notebook and its request ledger, the snapshot
// read, session_cards / session_briefs with their LM-102 keys, the
// entity_embeddings table, get_unfinished_work computed from that state, and
// the runtimes that call a model (extract-graph, close, brief, embed).
//
// The rules follow the SQL and the runtimes (see the migrations named
// below), so a test asserts "exactly once" on what the server holds and on
// how many model calls it counted, never on a mock's own call log.
//
// A [Phone] is one device: its own journal directory and skip store, its
// own network switch, and fresh service objects for each launch.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/logic/turn_state.dart' show ConversationTurn;
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/services/catch_up_service.dart';
import 'package:lumen/services/extract_graph_service.dart'
    show GraphExtractionException;
import 'package:lumen/services/headless_turn_finisher.dart';
import 'package:lumen/services/model_inputs.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/session_brief_service.dart';
import 'package:lumen/services/session_card_service.dart';
import 'package:lumen/services/turn_journal_service.dart';
import 'package:lumen/services/unfinished_work_service.dart';

import 'pseudonyms.dart';

String _hash(Object? json) =>
    sha256.convert(utf8.encode(jsonEncode(json))).toString();

class FakeNotebook {
  FakeNotebook(this.id, {this.mode = 'just_talk', required this.touched});

  final String id;
  final String mode;
  int revision = 0;

  /// Older than the 14-day catch-up window (20261118000500): never listed.
  bool outsideWindow = false;

  /// For "newest first" (get_unfinished_work orders by activity).
  int touched;
  final entries = <JournalEntry>[];
  final entities = <String, Entity>{};
}

class FakeCard {
  FakeCard(this.revision, this.card, {required this.hash, this.draft = false});
  final int revision;
  final Map<String, dynamic> card;

  /// Null for a draft: a draft never claims the key
  /// (20261116000050_card_draft_key.sql).
  final String? hash;
  final bool draft;
}

class FakeBrief {
  FakeBrief(this.notebookId, this.revision, this.hash);
  final String notebookId;
  final int revision;
  final String hash;
}

/// The server, shared by every phone of one account.
class FakeLumenServer {
  final notebooks = <String, FakeNotebook>{};
  var _clock = 0;

  /// notebook_commit_requests: (notebook, request id) -> (hash, result).
  final ledger = <(String, String), (String, CommitOutcome)>{};
  final cards = <String, FakeCard>{};

  /// session_briefs: one row per user.
  FakeBrief? brief;

  /// entity_embeddings: (notebook, entity) -> content hash.
  final vectors = <(String, String), String>{};

  // ── What was written (rows) and paid for (model calls). ──
  int commitsApplied = 0;
  int cardRowsWritten = 0;
  int briefRowsWritten = 0;
  int vectorRowsWritten = 0;
  int extractModelCalls = 0;
  int cardModelCalls = 0;
  int briefModelCalls = 0;
  int embedModelCalls = 0;

  /// Every server call that reached the server (for "the offline run
  /// changed nothing" and "B never asked about A's turn").
  final commitRequestIds = <String>[];

  int get rowsWritten =>
      commitsApplied + cardRowsWritten + briefRowsWritten + vectorRowsWritten;
  int get modelCalls =>
      extractModelCalls + cardModelCalls + briefModelCalls + embedModelCalls;

  /// What the extract-graph runtime answers per turn id (default: nothing
  /// to add).
  final extractions = <String, GraphPatch>{};

  /// extract-graph's cache: `notebook:turn` -> (input hash, patch).
  final _extractCache = <String, (String, GraphPatch)>{};

  /// `conversation_turns`: notebook -> turn id -> text, in save order. The
  /// card and the brief are written from THIS, as the app reads it, not from
  /// committed journal entries: a turn the phone never saved here is missing
  /// from the card.
  final transcripts = <String, Map<String, String>>{};

  /// The turn texts the card was last given, per notebook.
  final cardInputTexts = <String, List<String>>{};

  Future<void> saveTranscript(String notebookId, ConversationTurn turn) async {
    transcripts.putIfAbsent(notebookId, () => {}).putIfAbsent(
          turn.turnId,
          () => turn.text,
        );
  }

  /// Brief speak tokens -> the revision they were written for.
  final _speakTokens = <String, int>{};

  /// While set, the close runtime holds its answer (the model is writing).
  Completer<void>? holdClose;

  /// Completes when the first close reaches the runtime.
  final closeStarted = Completer<void>();

  // ── Seeding (what earlier sessions left on the server). ──

  FakeNotebook seedNotebook(
    String id, {
    List<String> userTurns = const [],
    List<Entity> entities = const [],
    bool vectorsBuilt = true,
    int? cardAt,
    int? briefAt,
    bool outsideWindow = false,
  }) {
    final nb = notebooks[id] = FakeNotebook(id, touched: ++_clock)
      ..outsideWindow = outsideWindow;
    for (final text in userTurns) {
      nb.revision++;
      transcripts.putIfAbsent(id, () => {})['seed-${nb.revision}'] = text;
      nb.entries.add(JournalEntry(
        id: 'seed-${nb.revision}',
        text: text,
        createdAt: DateTime.utc(2026, 11, 16, 8),
        entityIds: const [],
        relationIds: const [],
      ));
    }
    for (final e in entities) {
      nb.entities[e.id] = e;
      if (vectorsBuilt) vectors[(id, e.id)] = _contentHash(e);
    }
    if (cardAt != null) {
      final card = _cardJson(id, cardAt, 'seeded');
      cards[id] = FakeCard(cardAt, card, hash: _hash(card));
    }
    if (briefAt != null) brief = FakeBrief(id, briefAt, 'seeded');
    return nb;
  }

  NotebookSnapshot? snapshotOf(String id) {
    final nb = notebooks[id];
    if (nb == null) return null;
    return NotebookSnapshot(
      notebookId: id,
      revision: nb.revision,
      state: JournalState(
        entries: List.of(nb.entries),
        entities: Map.of(nb.entities),
        relations: const {},
        followUps: const [],
      ),
    );
  }

  // ── commit_notebook / get_notebook_snapshot ──

  Future<CommitOutcome> commitNotebook({
    required String notebookId,
    required int expectedRevision,
    required String requestId,
    required NotebookChange change,
  }) async {
    commitRequestIds.add(requestId);
    final nb = notebooks[notebookId];
    if (nb == null) return const CommitRejected(code: 'notFound');
    final hash = _hash(change.toJson());
    final seen = ledger[(notebookId, requestId)];
    if (seen != null) {
      // Same request, same change: the stored answer, nothing written.
      if (seen.$1 != hash) return const CommitRejected(code: 'requestIdReused');
      return seen.$2;
    }
    // A conflict writes no ledger row.
    if (expectedRevision != nb.revision) {
      return CommitConflict(currentRevision: nb.revision);
    }
    if (change is! ApplyTurnChange) {
      return const CommitRejected(code: 'invalidChange');
    }
    nb.revision++;
    nb.touched = ++_clock;
    final entryId = 'entry-$notebookId-${nb.revision}';
    nb.entries.add(JournalEntry(
      id: entryId,
      text: change.entryText,
      createdAt: DateTime.utc(2026, 11, 16, 9),
      entityIds: change.entryEntityIds,
      relationIds: change.entryRelationIds,
    ));
    for (final e in change.entities) {
      nb.entities[e.id] = e;
    }
    commitsApplied++;
    final outcome = CommitCommitted(
      requestId: requestId,
      revision: nb.revision,
      entryId: entryId,
    );
    ledger[(notebookId, requestId)] = (hash, outcome);
    return outcome;
  }

  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async =>
      snapshotOf(notebookId);

  // ── extract-graph: cached by turn id, a changed input refused (409). ──

  Future<GraphPatch> extract(HeadlessExtraction request) async {
    final key = '${request.notebookId}:${request.turnId}';
    final input = _hash(request.text);
    final cached = _extractCache[key];
    if (cached != null) {
      if (cached.$1 != input) {
        throw const GraphExtractionException('changed input',
            statusCode: 409, code: 'requestIdReused');
      }
      return cached.$2;
    }
    extractModelCalls++;
    final patch = extractions[request.turnId] ?? GraphPatch.empty();
    _extractCache[key] = (input, patch);
    return patch;
  }

  // ── RPCs ──

  Future<Object?> rpc(String fn, [Map<String, dynamic>? params]) async {
    final p = params ?? const {};
    switch (fn) {
      case 'get_unfinished_work':
        return unfinishedWork();
      case 'get_card_status':
        return _cardStatus(
            p['p_notebook_id'] as String, p['p_revision'] as int);
      case 'get_brief_status':
        return _briefStatus(
            p['p_notebook_id'] as String, p['p_revision'] as int);
      case 'save_session_card':
        return _saveCard(p);
      case 'save_session_brief':
        return _saveBrief(p);
    }
    throw StateError('unexpected rpc $fn');
  }

  /// 20261118000500_unfinished_work_window.sql, computed from this state.
  Map<String, dynamic> unfinishedWork() {
    final newest = notebooks.values.toList()
      ..sort((a, b) => b.touched.compareTo(a.touched));
    bool eligible(FakeNotebook nb) =>
        !nb.outsideWindow &&
        nb.mode == 'just_talk' &&
        nb.revision > 0 &&
        (nb.entries.isNotEmpty || nb.entities.isNotEmpty);

    final cardRows = [
      for (final nb in newest)
        if (eligible(nb))
          if (cards[nb.id] case final card
              when card == null ||
                  card.revision < nb.revision ||
                  (card.revision == nb.revision && card.draft))
            {
              'notebookId': nb.id,
              'revision': nb.revision,
              'cardRevision': card?.revision,
              if (card != null && card.draft) 'draft': true,
            },
    ];
    final latest = newest.where(eligible).firstOrNull;
    final briefRows = [
      if (latest != null &&
          !(brief?.notebookId == latest.id &&
              brief?.revision == latest.revision))
        {'notebookId': latest.id, 'revision': latest.revision},
    ];
    final vectorRows = [
      for (final nb in newest)
        if (nb.entities.isNotEmpty)
          if (nb.entities.keys
                  .where((e) => !vectors.containsKey((nb.id, e)))
                  .length
              case final missing when missing > 0)
            {
              'notebookId': nb.id,
              'entityCount': nb.entities.length,
              'missing': missing,
            },
    ];
    return {
      'cards': cardRows,
      'briefs': briefRows,
      'vectors': vectorRows,
      'erase': const [],
      'truncated': false,
    };
  }

  Map<String, dynamic> _cardStatus(String id, int revision) {
    final nb = notebooks[id];
    if (nb == null) {
      return {
        'status': 'notFound',
        'cardRevision': null,
        'currentRevision': null
      };
    }
    final card = cards[id];
    return {
      'status': revision != nb.revision
          ? 'stale'
          : card?.revision == revision
              ? 'present'
              : 'absent',
      'cardRevision': card?.revision,
      'currentRevision': nb.revision,
      if (card != null && card.draft) 'draft': true,
    };
  }

  Map<String, dynamic> _briefStatus(String id, int revision) {
    final nb = notebooks[id];
    if (nb == null) {
      return {
        'status': 'notFound',
        'briefRevision': null,
        'currentRevision': null
      };
    }
    final mine = brief?.notebookId == id ? brief!.revision : null;
    return {
      'status': revision != nb.revision
          ? 'stale'
          : mine == revision
              ? 'present'
              : 'absent',
      'briefRevision': mine,
      'currentRevision': nb.revision,
    };
  }

  /// save_session_card (20261116000000 + 20261116000050).
  Map<String, dynamic> _saveCard(Map<String, dynamic> p) {
    final id = p['p_notebook_id'] as String;
    final revision = p['p_source_revision'] as int;
    final card = (p['p_card'] as Map).cast<String, dynamic>();
    final draft = p['p_draft'] == true;
    final nb = notebooks[id];
    if (nb == null) return {'status': 'rejected', 'code': 'notFound'};
    if (!draft && revision != nb.revision) {
      return {'status': 'stale', 'currentRevision': nb.revision};
    }
    final stored = cards[id];
    if (stored != null && stored.revision > revision) {
      return {'status': 'saved', 'card': stored.card};
    }
    if (draft) {
      // A draft never claims the key, and never replaces a card at R.
      if (stored != null && stored.revision == revision) {
        return {'status': 'saved', 'card': stored.card};
      }
      cards[id] = FakeCard(revision, card, hash: null, draft: true);
      cardRowsWritten++;
      return {'status': 'saved', 'card': card};
    }
    final hash = _hash(card);
    if (stored != null && stored.revision == revision && !stored.draft) {
      if (stored.hash != hash) {
        return {'status': 'rejected', 'code': 'keyReused'};
      }
      return {'status': 'saved', 'card': stored.card};
    }
    cards[id] = FakeCard(revision, card, hash: hash);
    cardRowsWritten++;
    return {'status': 'saved', 'card': card};
  }

  /// save_session_brief (20261116000000): one row per user, keyed by
  /// (notebook, revision) with a payload hash.
  Map<String, dynamic> _saveBrief(Map<String, dynamic> p) {
    final id = p['p_notebook_id'] as String;
    final revision = p['p_source_revision'] as int;
    if (!notebooks.containsKey(id)) {
      return {'status': 'rejected', 'code': 'notFound'};
    }
    final hash = _hash(p['p_brief']);
    final stored = brief;
    if (stored != null &&
        stored.notebookId == id &&
        stored.revision == revision) {
      if (stored.hash != hash) {
        return {'status': 'rejected', 'code': 'keyReused'};
      }
      return {'status': 'unchanged'};
    }
    if (stored != null &&
        stored.notebookId == id &&
        stored.revision > revision) {
      return {'status': 'unchanged'};
    }
    brief = FakeBrief(id, revision, hash);
    briefRowsWritten++;
    return {'status': 'saved'};
  }

  Object? readCard(String id) => cards[id]?.card;

  // ── The notebook runtime (close, brief): each write is a model call. ──

  Future<http.Response> runtime(http.Request request) async {
    final segments = request.url.pathSegments; // v1 notebooks {id} close|brief
    final id = segments[2];
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (segments[3] == 'close') {
      if (!notebooks.containsKey(id)) return _json(404, {'code': 'notFound'});
      cardModelCalls++;
      if (!closeStarted.isCompleted) closeStarted.complete();
      final hold = holdClose;
      if (hold != null) await hold.future;
      // A model is not deterministic: each call writes a different card.
      return _json(200, {
        'status': 'ready',
        'saved': false,
        'card': _cardJson(id, body['sourceRevision'] as int, '$cardModelCalls'),
      });
    }
    if (body['speak'] case final Map speak) {
      final revision = _speakTokens[speak['speakToken']];
      if (revision == null) return _json(403, {'code': 'badToken'});
      return _json(200, {
        'status': 'ready',
        'audioBase64': 'AQID',
        'sampleRate': 24000,
        'openingLine': speak['openingLine'],
        'sourceRevision': revision,
      });
    }
    briefModelCalls++;
    final token = 'speak-$briefModelCalls';
    _speakTokens[token] = body['sourceRevision'] as int;
    return _json(200, {
      'status': 'ready',
      'brief': {
        'focus': <String>[],
        'openingThread': '',
        'openingLine': 'Good to hear from you again ($briefModelCalls).',
      },
      'speakToken': token,
      'sourceRevision': body['sourceRevision'],
    });
  }

  /// The model inputs the app reads from the notebook (revision first).
  CardInput cardInput(String id) {
    final nb = notebooks[id]!;
    final turns = _turns(nb);
    cardInputTexts[id] = [for (final t in turns) t.text];
    return CardInput(
      revision: nb.revision,
      turns: turns,
      candidates: const [],
    );
  }

  BriefInput briefInput(String id) {
    final nb = notebooks[id]!;
    return BriefInput(
      revision: nb.revision,
      turns: _turns(nb),
      previous: null,
      followUps: const [],
      questions: const [],
      topEntities: const [],
      entities: const [],
    );
  }

  List<InputTurn> _turns(FakeNotebook nb) => [
        for (final text
            in (transcripts[nb.id] ?? const <String, String>{}).values)
          (speaker: 'user', text: text, spokenAt: null),
      ];

  // ── Vectors: embed-reconcile, the server's sweep. ──

  /// The embed-reconcile sweep (cron) as it is today: builds a vector for
  /// each entity without a current one, keyed (notebook, entity) with the
  /// content hash. Returns how many it built.
  int reconcileVectors() {
    var built = 0;
    for (final nb in notebooks.values) {
      for (final e in nb.entities.values) {
        final hash = _contentHash(e);
        if (vectors[(nb.id, e.id)] == hash) continue;
        embedModelCalls++;
        vectors[(nb.id, e.id)] = hash;
        vectorRowsWritten++;
        built++;
      }
    }
    return built;
  }

  /// Which entities the last search found by vector (internal only).
  final semanticHits = <String>[];

  /// retrieve-memory (v2, user scope), simplified: a vector search over
  /// entities that have a vector, plus the lexical path over names, which
  /// answers without one. The packet never says how an entity was found.
  Future<dynamic> retrieveMemory(Map<String, dynamic> body) async {
    final query = (body['query'] as String).toLowerCase();
    final found = <Entity>[];
    semanticHits.clear();
    for (final nb in notebooks.values) {
      for (final e in nb.entities.values) {
        final matches = query.contains(e.name.toLowerCase());
        if (!matches) continue;
        if (vectors.containsKey((nb.id, e.id))) semanticHits.add(e.id);
        found.add(e);
      }
    }
    return {
      'version': 2,
      'context': found.isEmpty
          ? ''
          : 'Known people and things:\n'
              '${found.map((e) => '- ${e.name} (${e.type.name})').join('\n')}',
      'entityIds': [for (final e in found) e.id],
      'quotes': const [],
    };
  }

  static String _contentHash(Entity e) =>
      _hash({'name': e.name, 'type': e.type.name});

  static Map<String, dynamic> _cardJson(String id, int revision, String n) => {
        'version': 1,
        'notebookId': id,
        'conversationMode': 'just_talk',
        'sourceRevision': revision,
        'generatedAt': '2026-11-16T09:00:00.000Z',
        'title': 'A slower week',
        'summary': 'Card written by model call $n.',
        'remember': const [],
      };

  static http.Response _json(int status, Object body) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
      );
}

/// The model inputs, read from the server (as the app reads them).
class _ServerInputs implements ModelInputSource {
  _ServerInputs(this._phone);
  final Phone _phone;

  @override
  Future<CardInput> card(String notebookId) =>
      _phone.net(() async => _phone.server.cardInput(notebookId));

  @override
  Future<BriefInput> brief(String notebookId) =>
      _phone.net(() async => _phone.server.briefInput(notebookId));
}

/// One device: a journal directory and skip store that survive relaunches,
/// a network switch, and fresh services for each launch.
class Phone {
  Phone._(this.server, this.directory);

  static Future<Phone> create(FakeLumenServer server, String name) async {
    final dir = await Directory.systemTemp.createTemp('lumen-$name-');
    return Phone._(server, dir);
  }

  final FakeLumenServer server;
  final Directory directory;
  bool online = true;

  /// Every launch reads the same directory through new objects.
  TurnJournalService journal() =>
      TurnJournalService(directoryProvider: () async => directory);

  CatchUpSkipStore skipStore() =>
      FileCatchUpSkipStore(directoryProvider: () async => directory);

  /// Runs [call] over this phone's network: offline, nothing reaches the
  /// server.
  Future<T> net<T>(Future<T> Function() call) async {
    if (!online) throw const SocketException('offline');
    return call();
  }

  /// A runner as `catchUpRunnerFactoryProvider` builds it, over this
  /// phone's network: the real card, brief and work-list services and a
  /// fresh `HeadlessTurnFinisher`, with no real timers ([delay] is a future
  /// that never fires unless a test fires it).
  CatchUpRunner runner({
    String? Function()? openNotebookId,
    bool Function(String notebookId)? isNotebookLive,
    Set<String>? turnsStillRunning,
    Future<UnfinishedWork> Function()? loadWork,
    Future<void> Function(Duration)? delay,
  }) {
    final journal = this.journal();
    final inputs = _ServerInputs(this);
    Future<Object?> rpc(String fn, [Map<String, dynamic>? params]) =>
        net(() => server.rpc(fn, params));
    final client = MockClient((request) async {
      if (!online) throw http.ClientException('offline', request.url);
      return server.runtime(request);
    });
    final cards = SessionCardService(
      baseUrl: 'https://runtime.test',
      accessTokenProvider: () async => 'user-token',
      client: client,
      inputs: inputs,
      pseudonyms: testPseudonyms(),
      rpc: rpc,
      readCard: (id) => net(() async => server.readCard(id)),
      retryBaseDelay: Duration.zero,
    );
    final briefs = SessionBriefService(
      baseUrl: 'https://runtime.test',
      accessTokenProvider: () async => 'user-token',
      client: client,
      rpc: rpc,
      inputs: inputs,
      pseudonyms: testPseudonyms(),
    );
    final work = UnfinishedWorkService.withRpc(
      (fn, params) => net(() => server.rpc(fn, params)),
    );
    return CatchUpRunner(
      loadWork: loadWork ?? work.load,
      journalNotebookIds: journal.listNotebookIdsWithTurns,
      newTurnFinisher: () => HeadlessTurnFinisher(
        journal: journal,
        commit: ({
          required notebookId,
          required expectedRevision,
          required requestId,
          required change,
        }) =>
            net(() => server.commitNotebook(
                  notebookId: notebookId,
                  expectedRevision: expectedRevision,
                  requestId: requestId,
                  change: change,
                )),
        loadSnapshot: (id) => net(() => server.getNotebookSnapshot(id)),
        extract: (r) => net(() => server.extract(r)),
        redaction: TurnRedaction.none,
        saveTranscript: (id, turn) =>
            net(() => server.saveTranscript(id, turn)),
      ).finishNotebook,
      closeCard: (id) async => (await cards.close(id))?.sourceRevision,
      requestBrief: briefs.requestBrief,
      runErase: (_) async => true,
      // As in the app today: the phone does not build vectors.
      buildVectors: null,
      skips: skipStore(),
      openNotebookId: openNotebookId,
      isNotebookLive: isNotebookLive,
      turnsStillRunning: turnsStillRunning,
      now: () => DateTime.utc(2026, 11, 16, 9),
      delay: delay ?? (_) => Completer<void>().future,
    );
  }

  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
