// LM-56: extraction, the closing card and the brief send no known name to
// the runtime; results come back with the real names; each turn is swapped
// once and leaving joins cached pieces; the map runs off the UI isolate.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/testing.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';
import 'package:lumen/logic/slugify.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/providers/pseudonym_provider.dart';
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

    // The answer comes back after the map moved on: it is turned back with
    // the stand-ins the request was swapped with, and dropped (and asked for
    // once more) if one of them no longer stands for the same person.
    Future<(GraphPatch, List<http.Request>)> midFlight(
      PseudonymService pseudonyms,
      Future<void> Function(String fakePriya) change,
    ) async {
      final requests = <http.Request>[];
      final service = ExtractGraphService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        pseudonyms: pseudonyms,
        client: MockClient((request) async {
          requests.add(request);
          final context = (jsonDecode(request.body) as Map)['context'] as Map;
          final fake = ((context['entities'] as List).first as Map)['name'];
          if (requests.length == 1) await change(fake as String);
          return json({
            'patch': {
              'entities': [
                {'name': fake, 'type': 'person'},
              ],
              'relations': [],
              'supersedes': [],
            },
          });
        }),
      );
      final patch = await service.extract(
        notebookId: notebookId,
        turnId: 'turn-1',
        extractorVersion: 'v',
        text: 'Priya Raman called me today.',
        state: JournalState.empty().copyWith(entities: {priya.id: priya}),
        mode: 'granular',
        maxRetries: 0,
      );
      return (patch, requests);
    }

    test('a stand-in reissued mid-flight is not turned back', () async {
      final pseudonyms = testPseudonyms();
      late String oldFake;
      final (patch, requests) = await midFlight(pseudonyms, (fake) async {
        oldFake = fake;
        // A real person with the stand-in's name joins: the stand-in moves.
        await pseudonyms.syncGraph([priya, entity(slugify(fake), fake)]);
      });
      expect(requests, hasLength(2), reason: 'dropped and asked once more');
      final second =
          ((jsonDecode(requests[1].body) as Map)['context']['entities'] as List)
              .first['name'];
      expect(second, isNot(oldFake));
      expect(patch.entities.single.name, 'Priya Raman');
    });

    test('forgotten mid-flight: the retry neither turns back nor re-adds them',
        () async {
      final pseudonyms = testPseudonyms();
      final requests = <Map<String, dynamic>>[];
      String? oldFake;
      final service = ExtractGraphService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        pseudonyms: pseudonyms,
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(body);
          final names = [
            for (final e in body['context']['entities'] as List) e['name'],
          ];
          if (requests.length == 1) {
            // Priya's stand-in is the one for the entity with her id.
            oldFake = names.first as String;
            await pseudonyms.forget('priya-raman');
          }
          return json({
            'patch': {
              'entities': [
                // The model answers with every name it was given, and also
                // names her from the user's own words.
                for (final n in names) {'name': n, 'type': 'person'},
                {'name': 'Priya Raman', 'type': 'person'},
              ],
              'relations': [
                {
                  'source': 'Priya Raman',
                  'target': names.last,
                  'label': 'knows'
                },
              ],
              'supersedes': [],
            },
          });
        }),
      );
      // The extraction holds the state from before the forget.
      final patch = await service.extract(
        notebookId: notebookId,
        turnId: 'turn-1',
        extractorVersion: 'v',
        text: 'Priya Raman called me about Samantha.',
        state: JournalState.empty()
            .copyWith(entities: {priya.id: priya, sam.id: sam}),
        mode: 'granular',
        retrievedEntityIds: const ['priya-raman', 'samantha'],
        maxRetries: 0,
      );

      expect(requests, hasLength(2), reason: 'first answer dropped');
      // The retry's context no longer has her: not her stand-in, not her.
      final retried = jsonEncode(requests[1]['context']);
      expect(retried, isNot(contains(oldFake!)));
      expect(retried, isNot(contains('Priya')));
      expect(
        (requests[1]['context']['entities'] as List).map((e) => e['name']),
        hasLength(1),
      );
      // Nothing in the patch would re-create her.
      expect(patch.entities.map((e) => e.name), ['Samantha']);
      expect(patch.relations, isEmpty);
      expect(await pseudonyms.blockedIds(), {'priya-raman'});
      // And a later sync of a graph that still holds her doesn't bring her
      // stand-in back: her name is no longer swapped or turned back.
      await pseudonyms.syncGraph([priya, sam]);
      final again = await pseudonyms.swapTurns(['Priya Raman called.']);
      expect(again!.turns.single, 'Priya Raman called.');
      expect(again.snapshot.standIns, isEmpty);
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

    test('a card naming someone forgotten mid-flight is dropped, asked again',
        () async {
      final map = testPseudonyms();
      var calls = 0;
      final saves = <Map<String, dynamic>?>[];
      final service = SessionCardService(
        baseUrl: 'https://runtime.test',
        accessTokenProvider: () async => 'tok',
        retryBaseDelay: Duration.zero,
        inputs: FixedInputs(
          cardInput: CardInput(revision: 7, turns: turns, candidates: [priya]),
        ),
        pseudonyms: map,
        rpc: (fn, [params]) async {
          saves.add(params);
          return {'status': 'saved', 'card': params!['p_card']};
        },
        client: MockClient((request) async {
          calls++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final names = [for (final e in body['entities'] as List) e['name']];
          final fake = names.isEmpty ? 'someone' : names.first;
          if (calls == 1) await map.forget('priya-raman');
          return json({
            'status': 'ready',
            'saved': false,
            'card': {
              'version': 1,
              'notebookId': notebookId,
              'conversationMode': 'just_talk',
              'sourceRevision': 7,
              'generatedAt': '2026-11-07T10:00:00.000Z',
              'title': "$fake's move",
              'summary': 'You talked about $fake.',
              'remember': [],
              'notes': ['$fake is moving.'],
            },
          });
        }),
      );
      await service.close(notebookId);
      expect(calls, 2);
      expect(saves, hasLength(1));
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
        bool oldRuntime = false,
        int speakStatus = 200,
        String Function(String fake)? line,
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
            if (speakStatus != 200) {
              return json(
                  {'status': 'rejected', 'code': 'forbidden'}, speakStatus);
            }
            return json({
              'status': 'ready',
              'audioBase64': 'UENN',
              'sampleRate': 24000,
              'openingLine': (body['speak'] as Map)['openingLine'],
              'sourceRevision': 7,
            });
          }
          if (oldRuntime) return json({'status': 'ready'});
          if (writeStatus != 200) {
            return json({'status': 'rejected'}, writeStatus);
          }
          if (unchanged) return json({'status': 'unchanged'});
          final fake = ((body['topEntities'] as List).single as Map)['name'];
          return json({
            'status': 'ready',
            'sourceRevision': 7,
            'speakToken': 'ticket',
            'brief': {
              'focus': ['$fake is moving away'],
              'openingThread': "$fake's move",
              'openingLine': line?.call(fake as String) ??
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
          'speakToken': 'ticket',
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

    test('the write names the stand-ins it swapped in', () async {
      final b = build();
      await b.service.requestBrief(notebookId);
      final standIns = (b.bodies.first['standIns'] as List).cast<String>();
      expect(standIns, isNotEmpty);
      expectNoKnownName(jsonEncode(standIns));
    });

    test('a line too long to speak once names are back: text saved, no audio',
        () async {
      // Four stand-ins, each shorter than "Priya Raman", in a line just
      // under the cap: the real line is over it.
      final b = build(
        line: (fake) => '$fake, $fake, $fake and $fake: '
            '${'x' * (190 - 4 * fake.length - 9)}',
      );
      await b.service.requestBrief(notebookId);
      expect(b.bodies, hasLength(1), reason: 'no speak request');
      final save = b.saves.single!;
      expect(save['p_audio_base64'], isNull);
      expect(save['p_source_revision'], 7);
      final saved = (save['p_brief'] as Map)['openingLine'] as String;
      expect(saved.length, lessThanOrEqualTo(160));
      expect(saved, startsWith('Priya Raman, Priya Raman'));
      expect(saved, endsWith('…'));
    });

    test('a line the speak check refuses: text saved, no audio', () async {
      final b = build(speakStatus: 403);
      await b.service.requestBrief(notebookId);
      expect(b.bodies, hasLength(2));
      final save = b.saves.single!;
      expect(save['p_audio_base64'], isNull);
      expect((save['p_brief'] as Map)['openingLine'],
          "Hey, good to hear from you. How is Priya Raman's move going?");
    });

    test('a runtime from before v2 wrote the brief itself: done', () async {
      final b = build(oldRuntime: true);
      await b.service.requestBrief(notebookId);
      expect(b.bodies, hasLength(1));
      expect(b.saves, isEmpty);
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

    test('an unchanged graph is not synced again; a changed one is', () async {
      final host = CountingHost();
      final map = testPseudonyms(host: host);
      await map.syncGraph([priya, sam]);
      expect(host.count('_SyncEntitiesJob'), 1);
      await map.syncGraph([priya, sam]);
      expect(host.count('_SyncEntitiesJob'), 1, reason: 'same graph');
      await map.syncGraph([priya, sam, halvorsen]);
      expect(host.count('_SyncEntitiesJob'), 2, reason: 'graph changed');
    });

    test('the app builds the service on the isolate host', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(pseudonymServiceProvider).host,
          isA<IsolatePseudonymHost>());
    });

    test('a map that never settles: turns go as [omitted], nothing blocks',
        () async {
      final map = testPseudonyms(
        host: CountingHost(unsettled: true),
        refreshDelay: const Duration(days: 1),
      );
      await map.syncGraph([priya]);
      final out = await map.swapTurns(['Priya Raman called.', 'Then we ate.'],
          extras: ['Priya Raman']).timeout(const Duration(seconds: 5));
      expect(out!.turns, [omittedText, omittedText]);
      expect(out.extras, [omittedText]);
      expect(out.omitted, 3);
    });

    test('a piece that fails its round trip is sent as [omitted], counted',
        () async {
      final map = testPseudonyms(host: CountingHost(breakWhen: 'BREAK'));
      await map.syncGraph([priya]);
      final out = await map.swapTurns(
        ['Priya Raman called.', 'BREAK this one', 'Then we ate.'],
        extras: ['Priya Raman'],
      );
      expect(out!.turns[1], omittedText);
      expect(out.turns[2], 'Then we ate.');
      expect(out.omitted, 1);
      expect(out.turns[0], isNot(contains('Priya')));
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

/// Counts jobs by class; with [breakWhen], a swapped piece whose original
/// contains it comes back failing its round trip.
class CountingHost implements PseudonymHost {
  CountingHost({this.breakWhen, this.unsettled = false});
  final String? breakWhen;

  /// Every swap reports the map changed under the words it swapped, so the
  /// service's version never settles.
  final bool unsettled;
  final _inner = InlinePseudonymHost();
  final jobs = <String>[];

  int count(String job) => jobs.where((j) => j == job).length;

  @override
  Future<R> run<R>(PseudonymJob<R> job) async {
    jobs.add(job.runtimeType.toString());
    final result = await _inner.run(job);
    if (unsettled && result is (List<Dehydrated>, String?, Set<String>)) {
      final (List<Dehydrated> list, String? _, Set<String> _) =
          result as (List<Dehydrated>, String?, Set<String>);
      return (list, '{}', {'priya', 'raman', 'then'}) as R;
    }
    final marker = breakWhen;
    if (marker != null && result is (List<Dehydrated>, String?, Set<String>)) {
      final (List<Dehydrated> list, String? saved, Set<String> tokens) =
          result as (List<Dehydrated>, String?, Set<String>);
      return (
        [
          for (final d in list)
            d.original.contains(marker)
                ? Dehydrated(
                    original: d.original,
                    text: '${d.text} (not this)',
                    replacements: d.replacements,
                    mapChanged: false,
                  )
                : d,
        ],
        saved,
        tokens,
      ) as R;
    }
    return result;
  }
}

class _Throws extends PseudonymJob<int> {
  @override
  int run(PseudonymCell cell) => throw StateError('Priya Raman');
}
