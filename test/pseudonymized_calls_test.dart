// LM-56: extraction, the closing card and the brief send no known name to
// the runtime; results come back with the real names; each turn is swapped
// once and leaving joins cached pieces; the map runs off the UI isolate.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/logic/turn_state.dart' show Speaker;
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/follow_up.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/extract_graph_service.dart';
import 'package:lumen/services/model_inputs.dart';
import 'package:lumen/services/pseudonym_service.dart';
import 'package:lumen/services/pseudonym_worker.dart';
import 'package:lumen/services/session_brief_service.dart';
import 'package:lumen/services/session_card_service.dart';

import 'support/pseudonyms.dart';

const notebookId = '8e03b8f4-4f20-4df3-8398-d854adc32b14';

/// Every spelling of a known name, and the ids made from them.
const known = ['Priya', 'Raman', 'Samantha', 'Sam', 'Halvorsen'];
const knownIds = ['priya-raman', 'samantha', 'halvorsen-labs'];

final priya = entity('priya-raman', 'Priya Raman', mentions: 5);
final sam = entity('samantha', 'Samantha', aliases: ['Sam'], mentions: 3);
final halvorsen = entity('halvorsen-labs', 'Halvorsen Labs',
    type: EntityType.organization, mentions: 2);

/// Fails if any known name or id appears in [body] as a word.
void expectNoKnownName(String body) {
  for (final name in [...known, ...knownIds]) {
    expect(
      RegExp('\\b${RegExp.escape(name)}\\b', caseSensitive: false)
          .hasMatch(body),
      isFalse,
      reason: '"$name" reached a request body',
    );
  }
}

http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

JournalState graph() {
  final now = DateTime.utc(2026, 11, 1);
  return JournalState.empty().copyWith(
    entities: {
      for (final e in [priya, sam, halvorsen]) e.id: e
    },
    relations: {
      'priya-raman__sister_of__samantha': Relation(
        id: 'priya-raman__sister_of__samantha',
        source: 'priya-raman',
        target: 'samantha',
        label: 'sister_of',
        metadata: const {},
        createdAt: now,
      ),
    },
  );
}

void main() {
  group('extraction', () {
    test('sends no known name and swaps the patch back', () async {
      final requests = <http.Request>[];
      final pseudonyms = testPseudonyms();
      final service = ExtractGraphService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        pseudonyms: pseudonyms,
        client: MockClient((request) async {
          requests.add(request);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final context = body['context'] as Map<String, dynamic>;
          final names = {
            for (final e in context['entities'] as List)
              (e as Map)['id']: e['name'],
          };
          final relation = (context['relations'] as List).single as Map;
          // The model answers in the stand-ins it was given.
          return json({
            'patch': {
              'entities': [
                {
                  'name': names[relation['source']],
                  'type': 'person',
                  'description': '${names[relation['target']]} is her sister.',
                },
              ],
              'relations': [
                {
                  'source': names[relation['source']],
                  'target': names[relation['target']],
                  'label': 'cousin_of',
                },
              ],
              'supersedes': [relation['id'], 'never-offered'],
            },
          });
        }),
      );

      final patch = await service.extract(
        notebookId: notebookId,
        turnId: 'turn-1',
        extractorVersion: 'gemini/extract_graph/v2',
        text: 'Priya Raman told me Sam is her cousin, not her sister.',
        state: graph(),
        mode: 'granular',
        retrievedEntityIds: const ['samantha', 'halvorsen-labs'],
        recentConversation: [
          (role: Speaker.user, text: 'I saw Priya at Halvorsen Labs.'),
          (role: Speaker.assistant, text: 'How is Samantha doing?'),
        ],
        answeringFollowUp: FollowUp(
          id: 'f1',
          question: 'How is Samantha settling in?',
          reason: 'Sam moved',
          targetEntityIds: const ['samantha'],
          createdAt: DateTime.utc(2026, 11, 1),
          answered: false,
        ),
        maxRetries: 0,
      );

      expect(requests, hasLength(1));
      expectNoKnownName(requests.single.body);
      final context = (jsonDecode(requests.single.body) as Map)['context'];
      expect((context['entities'] as List), hasLength(3));

      expect(patch.entities.single.name, 'Priya Raman');
      expect(patch.entities.single.description, 'Samantha is her sister.');
      expect(patch.relations.single.source, 'Priya Raman');
      expect(patch.relations.single.target, 'Samantha');
      // The offered relation id maps back; one never offered is dropped.
      expect(patch.supersedes, ['priya-raman__sister_of__samantha']);
    });

    test('the same turn gets the same extractor version; the map adds a hash',
        () async {
      final versions = <String>[];
      final service = ExtractGraphService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        pseudonyms: testPseudonyms(),
        client: MockClient((request) async {
          versions.add((jsonDecode(request.body) as Map)['extractorVersion']);
          return json({
            'patch': {'entities': [], 'relations': [], 'supersedes': []},
          });
        }),
      );
      for (var i = 0; i < 2; i++) {
        await service.extract(
          notebookId: notebookId,
          turnId: 'turn-1',
          extractorVersion: 'gemini/extract_graph/v2',
          text: 'Priya Raman called me today.',
          state: graph(),
          mode: 'granular',
          maxRetries: 0,
        );
      }
      expect(versions[0], startsWith('gemini/extract_graph/v2#ps-'));
      expect(versions[0].length, lessThanOrEqualTo(100));
      expect(versions[1], versions[0]);
    });

    test('signed out: nothing is sent', () async {
      var called = false;
      final service = ExtractGraphService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        pseudonyms: testPseudonyms(owner: null),
        client: MockClient((_) async {
          called = true;
          return json({});
        }),
      );
      await expectLater(
        service.extract(
          notebookId: notebookId,
          turnId: 'turn-1',
          extractorVersion: 'v',
          text: 'Priya Raman called me today.',
          state: graph(),
          mode: 'granular',
          maxRetries: 0,
        ),
        throwsStateError,
      );
      expect(called, isFalse);
    });
  });

  group('closing card', () {
    const turns = <InputTurn>[
      (speaker: 'assistant', text: 'Hi, what is on your mind?', spokenAt: null),
      (speaker: 'user', text: 'Priya Raman is moving away.', spokenAt: null),
      (
        speaker: 'assistant',
        text: 'How do you feel about that?',
        spokenAt: null
      ),
      (
        speaker: 'user',
        text: 'Sad. Sam and I will help her pack.',
        spokenAt: null
      ),
    ];

    ({
      SessionCardService service,
      List<http.Request> requests,
      List<Map<String, dynamic>?> saves,
      PseudonymService pseudonyms
    }) build({
      List<Object> saveResults = const [],
      bool saved = false,
      PseudonymService? pseudonyms,
    }) {
      final requests = <http.Request>[];
      final saves = <Map<String, dynamic>?>[];
      final results = [...saveResults];
      final map = pseudonyms ?? testPseudonyms();
      final service = SessionCardService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        retryBaseDelay: Duration.zero,
        inputs: FixedInputs(
          cardInput: CardInput(
            revision: 7,
            turns: turns,
            candidates: [priya, sam],
          ),
        ),
        pseudonyms: map,
        rpc: (fn, [params]) async {
          expect(fn, 'save_session_card');
          saves.add(params);
          if (results.isNotEmpty) return results.removeAt(0);
          return {'status': 'saved', 'card': params!['p_card']};
        },
        client: MockClient((request) async {
          requests.add(request);
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final fakePriya = ((body['entities'] as List).first as Map)['name'];
          return json({
            'status': 'ready',
            'saved': saved,
            'card': {
              'version': 1,
              'notebookId': notebookId,
              'conversationMode': 'just_talk',
              'sourceRevision': body['sourceRevision'],
              'generatedAt': '2026-11-07T10:00:00.000Z',
              'title': "$fakePriya's move",
              'summary': 'You talked about $fakePriya moving away.',
              'remember': [
                {
                  'entityId': 'priya-raman',
                  'name': 'Priya Raman',
                  'type': 'person',
                  'note': '$fakePriya is moving away.',
                  'isNew': false,
                },
              ],
              'notes': ['$fakePriya is moving; you will help her pack.'],
            },
          });
        }),
      );
      return (
        service: service,
        requests: requests,
        saves: saves,
        pseudonyms: map
      );
    }

    test('sends no known name and saves the card with real names', () async {
      final b = build();
      final card = await b.service.close(notebookId);

      expect(b.requests, hasLength(1));
      expectNoKnownName(b.requests.single.body);
      final body = jsonDecode(b.requests.single.body) as Map;
      expect(body['version'], 2);
      expect(body['sourceRevision'], 7);
      expect((body['entities'] as List).map((e) => e['key']), [
        entityKey(notebookId, 'priya-raman'),
        entityKey(notebookId, 'samantha'),
      ]);

      final save = b.saves.single!;
      expect(save['p_notebook_id'], notebookId);
      expect(save['p_source_revision'], 7);
      expect(save.containsKey('p_draft'), isFalse);
      expect(save['p_title'], "Priya Raman's move");
      final stored = save['p_card'] as Map;
      expect(
          stored['notes'], ['Priya Raman is moving; you will help her pack.']);
      expect((stored['remember'] as List).single['note'],
          'Priya Raman is moving away.');
      expect(card!.title, "Priya Raman's move");
    });

    test('leaving joins turns already swapped: no whole-transcript swap',
        () async {
      final b = build();
      // Each turn is swapped once as it is saved (JournalNotifier._warmSwap).
      // The graph was synced as the conversation went on.
      await b.pseudonyms.syncGraph([priya, sam]);
      for (final turn in turns) {
        await b.pseudonyms.swapTurns([turn.text]);
      }
      final before = b.pseudonyms.swappedPieces;
      final longestTurn =
          turns.map((t) => t.text.length).reduce((a, b) => a > b ? a : b);

      await b.service.close(notebookId);

      // Only the two candidate names were swapped at leave, one by one.
      expect(b.pseudonyms.swappedPieces - before, 2);
      expect(b.pseudonyms.longestSwap, lessThanOrEqualTo(longestTurn));
    });

    test('a draft saves as a draft', () async {
      final b = build();
      await b.service.draft(notebookId);
      expect((jsonDecode(b.requests.single.body) as Map)['draft'], isTrue);
      expect(b.saves.single!['p_draft'], isTrue);
    });

    test('a stale save asks once more, then reports stale', () async {
      final once = build(saveResults: [
        {'status': 'stale', 'currentRevision': 8},
      ]);
      expect(await once.service.close(notebookId), isNotNull);
      expect(once.requests, hasLength(2));

      final twice = build(saveResults: [
        {'status': 'stale', 'currentRevision': 8},
        {'status': 'stale', 'currentRevision': 9},
      ]);
      await expectLater(
        twice.service.close(notebookId),
        throwsA(
            isA<SessionCardException>().having((e) => e.code, 'code', 'stale')),
      );
    });

    test('a stored card that is current is not saved again', () async {
      final b = build(saved: true);
      expect(await b.service.close(notebookId), isNotNull);
      expect(b.saves, isEmpty);
    });

    test('signed out: nothing is sent', () async {
      final b = build(pseudonyms: testPseudonyms(owner: null));
      await expectLater(b.service.close(notebookId), throwsStateError);
      expect(b.requests, isEmpty);
    });
  });

  group('brief', () {
    final input = BriefInput(
      revision: 7,
      turns: const [
        (
          speaker: 'user',
          text: 'Priya Raman is moving away.',
          spokenAt: '2026-11-07T09:00:00Z'
        ),
        (speaker: 'assistant', text: 'That is a big change.', spokenAt: null),
      ],
      previous: (
        focus: ['Sam started at Halvorsen Labs'],
        openingThread: 'Samantha'
      ),
      followUps: const ['How is Priya Raman doing?'],
      questions: const [
        (name: 'Samantha', questions: ['When does Sam start?']),
      ],
      topEntities: const [(name: 'Priya Raman', type: 'person')],
      entities: [priya, sam, halvorsen],
    );

    ({
      SessionBriefService service,
      List<Map<String, dynamic>> bodies,
      List<Map<String, dynamic>?> saves
    }) build(
        {bool unchanged = false,
        int writeStatus = 200,
        PseudonymService? pseudonyms}) {
      final bodies = <Map<String, dynamic>>[];
      final saves = <Map<String, dynamic>?>[];
      final service = SessionBriefService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        inputs: FixedInputs(briefInput: input),
        pseudonyms: pseudonyms ?? testPseudonyms(),
        rpc: (fn, [params]) async {
          expect(fn, 'save_session_brief');
          saves.add(params);
          return {'status': 'saved'};
        },
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          bodies.add(body);
          if (body['speak'] != null) {
            return json({
              'status': 'ready',
              'audioBase64': 'UENN',
              'sampleRate': 24000
            });
          }
          if (writeStatus != 200) {
            return json({'status': 'rejected'}, writeStatus);
          }
          if (unchanged) return json({'status': 'unchanged'});
          final fake = ((body['topEntities'] as List).single as Map)['name'];
          return json({
            'status': 'ready',
            'sourceRevision': 7,
            'brief': {
              'focus': ['$fake is moving away'],
              'openingThread': "$fake's move",
              'openingLine':
                  "Hey, good to hear from you. How is $fake's move going?",
            },
          });
        }),
      );
      return (service: service, bodies: bodies, saves: saves);
    }

    test('the text model gets no known name; only the spoken line has one',
        () async {
      final b = build();
      await b.service.requestBrief(notebookId);

      expect(b.bodies, hasLength(2));
      final [write, speak] = b.bodies;
      expectNoKnownName(jsonEncode(write));
      expect(write['version'], 2);
      expect(write['sourceRevision'], 7);
      expect(speak, {
        'version': 2,
        'speak': {
          'openingLine':
              "Hey, good to hear from you. How is Priya Raman's move going?",
          'sourceRevision': 7,
        },
      });

      final save = b.saves.single!;
      expect(save['p_source_revision'], 7);
      expect(save['p_audio_base64'], 'UENN');
      expect(save['p_sample_rate'], 24000);
      expect(save['p_brief'], {
        'focus': ['Priya Raman is moving away'],
        'openingThread': "Priya Raman's move",
        'openingLine':
            "Hey, good to hear from you. How is Priya Raman's move going?",
      });
    });

    test('unchanged: no speech, no save', () async {
      final b = build(unchanged: true);
      await b.service.requestBrief(notebookId);
      expect(b.bodies, hasLength(1));
      expect(b.saves, isEmpty);
    });

    test('a runtime rejection keeps its status for the retry rules', () async {
      final b = build(writeStatus: 429);
      await expectLater(
        b.service.requestBrief(notebookId),
        throwsA(isA<SessionBriefException>()
            .having((e) => e.statusCode, 'statusCode', 429)),
      );
      expect(b.saves, isEmpty);
    });

    test('signed out: nothing is sent', () async {
      final b = build(pseudonyms: testPseudonyms(owner: null));
      await expectLater(b.service.requestBrief(notebookId), throwsStateError);
      expect(b.bodies, isEmpty);
    });
  });

  test('entity keys match the runtime (sha256 of "<notebook>:<id>")', () {
    // infra/test/pseudonymized-requests.test.mjs checks the same value.
    expect(entityKey('nb', 'priya'),
        '9902b537b3bde363cd3c707689214fce6f246daceeae93abf99f68ab086bf511');
  });

  group('swap cache', () {
    test('a turn is swapped once; a change only re-swaps turns it touches',
        () async {
      final map = testPseudonyms(refreshDelay: const Duration(days: 1));
      await map.syncGraph([priya]);
      const a = 'Priya Raman called.';
      const b = 'Dinner with Samantha tonight.';
      await map.swapTurns([a, b]);
      expect(map.swappedPieces, 2);
      await map.swapTurns([a, b]);
      expect(map.swappedPieces, 2, reason: 'cached');

      // Samantha joins the graph: only the turn that names her is stale.
      await map.syncGraph([priya, sam]);
      final out = await map.swapTurns([a, b]);
      expect(map.swappedPieces, 3);
      expect(out!.turns[1], isNot(contains('Samantha')));
    });

    test('an unchanged graph is not synced again', () async {
      final map = testPseudonyms();
      await map.syncGraph([priya, sam]);
      final store = MemoryStore();
      expect(store.saved, isNull);
      final first = (await map.dehydrateAll(['Priya Raman']))!.single;
      await map.syncGraph([priya, sam]);
      expect((await map.dehydrateAll(['Priya Raman']))!.single, first);
    });

    test('the map runs in a background isolate by default', () async {
      final map = PseudonymService(ownerId: () => 'u1', store: MemoryStore());
      await map.syncGraph([priya]);
      final out = await map.swapTurns(['Priya Raman called.']);
      expect(out!.turns.single, isNot(contains('Priya')));
      expect(await map.rehydrateModelOutput(out.turns.single),
          'Priya Raman called.');
    });

    test('the isolate host reports a failed job by class only', () async {
      final host = IsolatePseudonymHost();
      await expectLater(
        host.run(_Throws()),
        throwsA(isA<PseudonymJobFailed>()
            .having((e) => e.toString(), 'text', isNot(contains('Priya')))),
      );
    });
  });
}

class _Throws extends PseudonymJob<int> {
  @override
  int run(PseudonymCell cell) => throw StateError('Priya Raman');
}
