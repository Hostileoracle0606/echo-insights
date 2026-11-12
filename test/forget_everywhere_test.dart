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
      expect(r.spells('priya-raman-foundation'), isFalse);
    });

    test('knows an id that spells the name', () {
      final r = _forgetPriya();
      expect(r.spells('priya-raman-foundation'), isTrue);
      expect(r.spells('the-priya-raman-fund'), isTrue);
      expect(r.spells('priya-ramanathan'), isFalse);
      expect(r.spells('priya-nair'), isFalse);
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
}
