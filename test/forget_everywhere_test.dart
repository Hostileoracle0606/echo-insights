import 'dart:async';
// LM-63: once a person is forgotten, nothing the app assembles for a model
// names them, no graph state holds them (ids that spell the name included),
// and the user's own transcript keeps their words.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/logic/forget_redaction.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/follow_up.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/extract_graph_service.dart';
import 'package:lumen/services/model_inputs.dart';
import 'package:lumen/services/transcript_store.dart';

import 'support/pseudonyms.dart';

final _t0 = DateTime.utc(2026, 11, 1);

/// Fails if the forgotten name, in any case, or her id reaches [body].
void expectNoForgottenName(String body) {
  for (final word in ['raman', 'priya-raman']) {
    expect(body.toLowerCase().contains(word), isFalse,
        reason: '"$word" reached a request body: $body');
  }
}

ForgetRedactor _forgetPriya() =>
    ForgetRedactor()..add('priya-raman', ['Priya Raman']);

JournalState _graph() => JournalState.empty().copyWith(
      entities: {
        for (final e in [
          entity('priya-raman', 'Priya Raman'),
          entity('e-1700000000000', 'Priya Raman'),
          entity('priya-raman-foundation', 'Priya Raman Foundation',
              type: EntityType.organization),
          entity('priya-nair', 'Priya Nair'),
          Entity(
            id: 'city-marathon',
            name: 'City Marathon',
            type: EntityType.event,
            description: "Priya Raman's first marathon",
            metadata: const {'runner': 'Priya Raman', 'Priya Raman': 'key'},
            mentions: 1,
            firstSeen: _t0,
            lastSeen: _t0,
            questions: const ['How is Priya Raman\'s training going?'],
          ),
        ])
          e.id: e,
      },
      relations: {
        'priya-raman-foundation__funds__city-marathon': Relation(
          id: 'priya-raman-foundation__funds__city-marathon',
          source: 'priya-raman-foundation',
          target: 'city-marathon',
          label: 'funds',
          metadata: const {},
          createdAt: _t0,
        ),
        'priya-nair__runs__city-marathon': Relation(
          id: 'priya-nair__runs__city-marathon',
          source: 'priya-nair',
          target: 'city-marathon',
          label: 'runs',
          metadata: const {'with': 'Priya Raman'},
          createdAt: _t0,
        ),
      },
      entries: [
        JournalEntry(
          id: 'e1',
          text: 'Priya Raman ran with Priya Nair.',
          createdAt: _t0,
          entityIds: const ['priya-nair', 'priya-raman-foundation'],
          relationIds: const ['priya-raman-foundation__funds__city-marathon'],
        ),
      ],
      followUps: [
        FollowUp(
          id: 'f1',
          question: 'How is Priya Raman?',
          reason: '',
          targetEntityIds: const [],
          createdAt: _t0,
          answered: false,
        ),
        FollowUp(
          id: 'f2',
          question: 'Did the charity pay?',
          reason: '',
          targetEntityIds: const ['priya-raman-foundation'],
          createdAt: _t0,
          answered: false,
        ),
        FollowUp(
          id: 'f3',
          question: 'How is the marathon going?',
          reason: '',
          targetEntityIds: const ['city-marathon'],
          createdAt: _t0,
          answered: false,
        ),
      ],
    );

void main() {
  group('ForgetRedactor', () {
    test('redacts the whole name in any case, as the server does', () {
      final r = _forgetPriya();
      expect(r.redact('PRIYA RAMAN called. priya raman too. Priya-Raman, Priya Raman\'s.'),
          'someone called. someone too. someone, someone\'s.');
    });

    test('leaves other names, longer names and parts alone', () {
      final r = _forgetPriya();
      const text = 'Priya Nair met Priya Ramanathan and Priya.';
      expect(r.redact(text), text);
    });

    test('a one-word name only when capitalised', () {
      final r = ForgetRedactor()..add('will', ['Will']);
      expect(r.redact('Will said we will go.'), 'someone said we will go.');
    });

    test('does nothing until someone is forgotten, and forgets on clear', () {
      final r = ForgetRedactor();
      expect(r.redact('Priya Raman'), 'Priya Raman');
      r.add('priya-raman', ['Priya Raman']);
      expect(r.isEmpty, isFalse);
      r.clear();
      expect(r.redact('Priya Raman'), 'Priya Raman');
      expect(r.spells('priya-raman-foundation', 'Priya Raman Foundation'), isFalse);
    });

    test('knows an id that spells the name', () {
      final r = _forgetPriya();
      expect(r.spells('priya-raman-foundation', 'Priya Raman Foundation'), isTrue);
      expect(r.spells('the-priya-raman-fund', 'The Priya Raman Fund'), isTrue);
      expect(r.spells('priya-ramanathan', 'Priya Ramanathan'), isFalse);
      expect(r.spells('priya-nair', 'Priya Nair'), isFalse);
    });

    test('the graph state as the server leaves it (BUG-4, BUG-5)', () {
      final r = _forgetPriya();
      final next = r.redactState(_graph());
      expect(next.entities.keys, unorderedEquals(['city-marathon', 'priya-nair']),
          reason: 'her, her duplicate under another id, and the id that spells her');
      final marathon = next.entities['city-marathon']!;
      expect(marathon.description, "someone's first marathon");
      expect(marathon.questions, ["How is someone's training going?"]);
      expect(marathon.metadata, {'runner': 'someone', 'someone': 'key'});
      expect(next.relations.keys, ['priya-nair__runs__city-marathon']);
      expect(next.relations.values.single.metadata, {'with': 'someone'});
      expect(next.entries.single.text, 'someone ran with Priya Nair.');
      expect(next.entries.single.entityIds, ['priya-nair']);
      expect(next.entries.single.relationIds, isEmpty);
      expect(next.followUps.map((f) => f.id), ['f3']);
      expectNoForgottenName(jsonEncode({
        'entities': [for (final e in next.entities.values) e.toJson()],
        'relations': [for (final r in next.relations.values) r.toJson()],
        'entries': [for (final e in next.entries) e.toJson()],
        'followUps': [for (final f in next.followUps) f.toJson()],
      }));
    });

    test('a turn reads as the server redacted it, then this run\'s names', () {
      final r = ForgetRedactor()..add('dana-whit', ['Dana Whit']);
      const saved = ConversationTurn(
        turnId: 't1',
        role: Speaker.user,
        text: 'Priya Raman and Dana Whit came.',
        createdAt: '2026-11-01T00:00:00Z',
        contextText: 'someone and Dana Whit came.',
      );
      final read = r.turnForLumen(saved);
      expect(read.text, 'someone and someone came.');
      expect(read.turnId, 't1');
      expect(saved.text, 'Priya Raman and Dana Whit came.',
          reason: 'the transcript view keeps the words');
    });
  });

  group('rows as the server returns them', () {
    test('the model reads a turn\'s context_text', () {
      final turn = inputTurnFromRow({
        'speaker': 'user',
        'text': 'Priya Raman called.',
        'context_text': 'someone called.',
        'spoken_at': '2026-11-01T00:00:00Z',
      });
      expect(turn.text, 'someone called.');
      expect(inputTurnFromRow({'speaker': 'assistant', 'text': 'Hi.', 'spoken_at': null}).text, 'Hi.');
    });

    test('the transcript keeps text and carries context_text alongside', () {
      final turn = turnFromRow({
        'turn_id': 't1',
        'speaker': 'user',
        'text': 'Priya Raman called.',
        'context_text': 'someone called.',
        'spoken_at': '2026-11-01T00:00:00Z',
        'input': 'voice',
      });
      expect(turn.text, 'Priya Raman called.');
      expect(turn.contextText, 'someone called.');
    });
  });

  group('extraction request', () {
    http.Response json(Object body) => http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json'});

    test('a forgotten name never reaches the body, the turn included', () async {
      final bodies = <String>[];
      final service = ExtractGraphService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        pseudonyms: testPseudonyms(),
        forgotten: _forgetPriya(),
        client: MockClient((request) async {
          bodies.add(request.body);
          return json({
            'patch': {'entities': [], 'relations': [], 'supersedes': []},
          });
        }),
      );
      await service.extract(
        notebookId: 'nb',
        turnId: 't1',
        extractorVersion: 'v',
        text: 'Priya Raman called about the City Marathon.',
        state: _graph(),
        mode: 'granular',
        recentConversation: const [
          (role: Speaker.assistant, text: 'How is Priya Raman?'),
        ],
        retrievedEntityIds: const ['priya-raman', 'priya-raman-foundation', 'city-marathon'],
        answeringFollowUp: _graph().followUps.first,
        maxRetries: 0,
      );
      expect(bodies, hasLength(1));
      expectNoForgottenName(bodies.single);
    });

    test('forgotten mid-flight: the retry carries no name either', () async {
      final pseudonyms = testPseudonyms();
      final forgotten = ForgetRedactor();
      final bodies = <String>[];
      final service = ExtractGraphService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        pseudonyms: pseudonyms,
        forgotten: forgotten,
        client: MockClient((request) async {
          bodies.add(request.body);
          final names = [
            for (final e in (jsonDecode(request.body) as Map)['context']['entities'] as List)
              e['name'],
          ];
          if (bodies.length == 1) {
            // The forget lands while the first request is out.
            forgotten.add('priya-raman', ['Priya Raman']);
            await pseudonyms.forget('priya-raman');
          }
          return json({
            'patch': {
              'entities': [for (final n in names) {'name': n, 'type': 'person'}],
              'relations': [],
              'supersedes': [],
            },
          });
        }),
      );
      await service.extract(
        notebookId: 'nb',
        turnId: 't1',
        extractorVersion: 'v',
        text: 'Priya Raman called me today.',
        state: JournalState.empty().copyWith(entities: {
          'priya-raman': entity('priya-raman', 'Priya Raman'),
        }),
        mode: 'granular',
        maxRetries: 0,
      );
      expect(bodies, hasLength(2), reason: 'dropped and asked once more');
      expectNoForgottenName(bodies.last);
      expect((jsonDecode(bodies.last) as Map)['text'], 'someone called me today.');
    });
  });

  group('name map (BUG-7)', () {
    test('forget drops the name\'s words from reserved, keeping words others use', () {
      final map = PseudonymMap(ownerId: 'u1')
        ..sync([
          PseudonymEntity.fromEntity(entity('priya-raman', 'Priya Raman'))!,
          PseudonymEntity.fromEntity(entity('priya-nair', 'Priya Nair'))!,
        ], allNames: ['Priya Raman', 'Priya Nair']);
      map.forget('priya-raman');
      final reserved = (map.toJson()['reserved'] as List).cast<String>();
      expect(reserved, isNot(contains('raman')));
      expect(reserved, containsAll(['priya', 'nair']),
          reason: 'Priya Nair is still a real name: no stand-in may take it');
    });
  });

  group('redaction is not repeated for the same text (Phase 2, M2)', () {
    JournalState journal(int n) => JournalState.empty().copyWith(entries: [
          for (var i = 0; i < n; i++)
            JournalEntry(
              id: 'e$i',
              text: i == 3 ? 'Priya Raman called me' : 'Walked the dog $i',
              createdAt: DateTime.utc(2026, 11, 1),
              entityIds: const [],
              relationIds: const [],
            ),
        ]);

    test('the second pass over a state scans nothing new', () {
      final r = ForgetRedactor()..add('priya-raman', ['Priya Raman']);
      final first = r.redactState(journal(500));
      final scanned = r.scans;
      expect(scanned, greaterThanOrEqualTo(500));
      final second = r.redactState(journal(500));
      expect(r.scans, scanned, reason: 'every text came from the cache');
      expect(second.entries[3].text, first.entries[3].text);
      expect(first.entries[3].text, 'someone called me');
    });

    test('a new forget is applied to texts already cached', () {
      final r = ForgetRedactor();
      r.add('will', ['Will']);
      expect(r.redact('Priya Raman called'), 'Priya Raman called');
      r.add('priya-raman', ['Priya Raman']);
      expect(r.redact('Priya Raman called'), 'someone called');
    });

    test('sign-out empties the cache', () async {
      final store = MemoryStore();
      final r = ForgetRedactor(store: store, ownerId: () => 'u1');
      await r.ensureLoaded();
      r.add('priya-raman', ['Priya Raman']);
      expect(r.redact('Priya Raman called'), 'someone called');
      await r.clear();
      expect(r.redact('Priya Raman called'), 'Priya Raman called');
    });
  });

  group('owners and in-flight loads (Phase 2, M7)', () {
    test('a load in flight for one owner is not reused for the next', () async {
      final store = _SlowStore();
      final a = ForgetRedactor(store: store, ownerId: () => 'owner-a');
      await a.ensureLoaded();
      a.add('priya-raman', ['Priya Raman']);
      await a.flush();
      store.delay = true;

      var owner = 'owner-a';
      final r = ForgetRedactor(store: store, ownerId: () => owner);
      final first = r.ensureLoaded();
      owner = 'owner-b';
      final second = r.ensureLoaded();
      store.release();
      await Future.wait([first, second]);

      expect(r.isEmpty, isTrue, reason: "owner-b must not inherit owner-a's hashes");
      expect(r.redact('Priya Raman called'), 'Priya Raman called');
    });
  });

  group('stored forgotten names (fix round 1)', () {
    test('hashes only, matched like the server after a reload', () async {
      final store = MemoryStore();
      final first = ForgetRedactor(store: store, ownerId: () => 'u1');
      await first.ensureLoaded();
      first.add('priya-raman', ['Priya Raman']);
      first.add('will', ['Will']);
      first.add('li-lei', ['李雷']);
      await first.flush();
      final saved = store.saved!.toLowerCase();
      for (final word in ['priya', 'raman', 'will', '李雷']) {
        expect(saved, isNot(contains(word)), reason: '"$word" stored');
      }

      final again = ForgetRedactor(store: store, ownerId: () => 'u1');
      await again.ensureLoaded();
      expect(again.redact('PRIYA RAMAN called. Priya-Raman too.'), 'someone called. someone too.');
      expect(again.redact('Priya Nair met Priya Ramanathan.'), 'Priya Nair met Priya Ramanathan.');
      expect(again.redact('Will said we will go.'), 'someone said we will go.');
      expect(again.redact('我和李雷去了'), '我和someone去了');
    });

    test('ids are judged by the entity name: forgetting Will, Grace and Mark', () {
      final r = ForgetRedactor()
        ..add('will', ['Will'])
        ..add('grace', ['Grace'])
        ..add('mark', ['Mark']);
      final state = JournalState.empty().copyWith(entities: {
        for (final e in [
          entity('will-power', 'will power', type: EntityType.concept),
          entity('good-will', 'good will', type: EntityType.concept),
          entity('grace-period', 'grace period', type: EntityType.concept),
          entity('mark-down', 'mark down', type: EntityType.concept),
          entity('grace-hopper-prize', 'Grace Hopper Prize', type: EntityType.event),
        ])
          e.id: e,
      });
      final next = r.redactState(state);
      expect(next.entities.keys,
          unorderedEquals(['will-power', 'good-will', 'grace-period', 'mark-down']));
      expect(r.spells('will-power', 'will power'), isFalse);
      expect(r.spells('grace-hopper-prize', 'Grace Hopper Prize'), isTrue);
    });

    test('sign-out clears memory and the store', () async {
      final store = MemoryStore();
      final r = ForgetRedactor(store: store, ownerId: () => 'u1');
      await r.ensureLoaded();
      r.add('priya-raman', ['Priya Raman']);
      await r.flush();
      await r.clear();
      expect(store.saved, isNull);
      expect(r.redact('Priya Raman'), 'Priya Raman');
    });
  });
}

class _SlowStore extends MemoryStore {
  bool delay = false;
  final _gate = Completer<void>();
  void release() => _gate.complete();

  @override
  Future<String?> read() async {
    if (delay) await _gate.future;
    return super.read();
  }
}
