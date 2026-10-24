import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/memory_quote.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/retrieve_memory_service.dart';

Map<String, dynamic> _fixtureFor(String name) => jsonDecode(
      File('contracts/fixtures/$name').readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  final now = DateTime.utc(2026, 6, 13, 9);

  Map<String, dynamic> fixture(String name) => jsonDecode(
        File('contracts/fixtures/$name').readAsStringSync(),
      ) as Map<String, dynamic>;

  test('parses the shared retrieve-memory v1 success fixture', () {
    final result = MemoryRetrieval.fromData(
      fixture('retrieve-memory-v1.success.json'),
    );

    expect(result.context, 'Maya works on Project Atlas.');
    expect(result.entityIds, ['maya', 'project-atlas']);
  });

  test('parses the shared retrieve-memory v1 empty fixture', () {
    final result = MemoryRetrieval.fromData(
      fixture('retrieve-memory-v1.empty.json'),
    );

    expect(result.context, isEmpty);
    expect(result.entityIds, isEmpty);
  });

  test('rejects legacy, future, and malformed retrieval responses', () {
    expect(
      () => MemoryRetrieval.fromData({
        'context': 'legacy',
        'entityIds': <String>[],
      }),
      throwsFormatException,
    );
    expect(
      () => MemoryRetrieval.fromData({
        'version': 3,
        'context': 'future',
        'entityIds': <String>[],
      }),
      throwsFormatException,
    );
    expect(
      () => MemoryRetrieval.fromData({
        'version': 1,
        'context': 'bad',
        'entityIds': ['maya', 4],
      }),
      throwsFormatException,
    );
  });

  test('stateToGraphloop emits graphloop camelCase keys, not snake_case', () {
    final state = JournalState(
      entries: [
        JournalEntry(
          id: 'e1',
          text: 'Maya works on Atlas.',
          createdAt: now,
          entityIds: const ['maya', 'atlas'],
          relationIds: const ['r1'],
        ),
      ],
      entities: {
        'maya': Entity(
          id: 'maya',
          name: 'Maya',
          type: EntityType.person,
          metadata: const {},
          mentions: 2,
          firstSeen: now,
          lastSeen: now,
          questions: const ['Who is Maya?'],
        ),
      },
      relations: {
        'r1': Relation(
          id: 'r1',
          source: 'maya',
          target: 'atlas',
          label: 'works_on',
          metadata: const {},
          createdAt: now,
          supersededAt: now,
        ),
      },
      followUps: const [],
    );

    final out = stateToGraphloop(state);

    // Entities keyed by id; camelCase timestamp fields.
    final maya = (out['entities'] as Map)['maya'] as Map;
    expect(maya['firstSeen'], '2026-06-13T09:00:00.000Z');
    expect(maya['lastSeen'], '2026-06-13T09:00:00.000Z');
    expect(maya.containsKey('first_seen'), isFalse);
    expect(maya['type'], 'person');

    // Relations: camelCase createdAt / supersededAt.
    final r1 = (out['relations'] as Map)['r1'] as Map;
    expect(r1['createdAt'], '2026-06-13T09:00:00.000Z');
    expect(r1['supersededAt'], '2026-06-13T09:00:00.000Z');
    expect(r1.containsKey('superseded_at'), isFalse);

    // Entries: list with camelCase entityIds / relationIds.
    final e1 = (out['entries'] as List).first as Map;
    expect(e1['entityIds'], ['maya', 'atlas']);
    expect(e1['relationIds'], ['r1']);
    expect(e1.containsKey('entity_ids'), isFalse);

    // followUps dropped.
    expect(out.containsKey('followUps'), isFalse);
  });

  group('v2 (user scope, quotes)', () {
    test('parses the shared v2 success fixture with quotes', () {
      final result = MemoryRetrieval.fromData(
        fixture('retrieve-memory-v2.success.json'),
      );

      expect(result.entityIds, ['priya', 'ci-fix']);
      expect(result.quotes, hasLength(2));
      final first = result.quotes.first;
      expect(first.entryId, '2c7d6a51-3f0e-4c1b-9f43-8a1de2b7c901');
      expect(first.notebookId, '6f1c0a9e-1b2d-4e8f-a3c4-5d6e7f809a1b');
      expect(first.turnId, 'turn-7f3a');
      expect(first.spokenAt, DateTime.utc(2026, 10, 16, 17, 42, 10));
      expect(first.createdAt, DateTime.utc(2026, 10, 16, 17, 42, 13));
      expect(first.notebookTitle, 'Friday wrap-up');
      expect(first.text, startsWith('Priya said the CI fix is next'));
      expect(result.quotes.last.turnId, isNull);
      expect(result.quotes.last.spokenAt, isNull);
    });

    test('parses the shared v2 empty and no-quotes fixtures', () {
      final empty = MemoryRetrieval.fromData(
        fixture('retrieve-memory-v2.empty.json'),
      );
      expect(empty.context, isEmpty);
      expect(empty.quotes, isEmpty);

      final noQuotes = MemoryRetrieval.fromData(
        fixture('retrieve-memory-v2.no-quotes.json'),
      );
      expect(noQuotes.entityIds, ['priya']);
      expect(noQuotes.quotes, isEmpty);
    });

    test('v1 responses parse with no quotes', () {
      final result = MemoryRetrieval.fromData(
        fixture('retrieve-memory-v1.success.json'),
      );
      expect(result.quotes, isEmpty);
    });

    test('rejects v2 without quotes or with malformed quotes', () {
      final base = {
        'version': 2,
        'context': 'c',
        'entityIds': <String>[],
      };
      expect(() => MemoryRetrieval.fromData(base), throwsFormatException);
      expect(
        () => MemoryRetrieval.fromData({
          ...base,
          'quotes': [
            {'entryId': 'e1', 'text': 'missing fields'},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => MemoryRetrieval.fromData({
          ...base,
          'quotes': [
            {
              'entryId': 'e1',
              'notebookId': 'nb',
              'turnId': null,
              'spokenAt': null,
              'createdAt': 'not a date',
              'notebookTitle': 't',
              'text': 'x',
            },
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('RetrieveMemoryService request', () {
    final state = JournalState.empty();

    test('user scope sends scope and no state', () async {
      Map<String, dynamic>? sent;
      final service = RetrieveMemoryService.withInvoker((body) async {
        sent = body;
        return fixture('retrieve-memory-v2.success.json');
      });

      final result = await service.retrieveResult(
        query: ' Priya ',
        notebookId: 'nb-open',
        scope: RetrievalScope.user,
      );

      expect(sent, {'query': 'Priya', 'notebookId': 'nb-open', 'scope': 'user'});
      expect(result.quotes, hasLength(2));
    });

    test('notebook scope sends the graph and no scope (old contract)', () async {
      Map<String, dynamic>? sent;
      final service = RetrieveMemoryService.withInvoker((body) async {
        sent = body;
        return fixture('retrieve-memory-v1.success.json');
      });

      await service.retrieveResult(
        query: 'Maya',
        notebookId: 'nb-open',
        state: state,
      );

      expect(sent!.keys, unorderedEquals(['query', 'notebookId', 'state']));
    });

    test('errors, contract mismatches and timeouts degrade to empty', () async {
      final failing = RetrieveMemoryService.withInvoker(
        (_) async => throw Exception('network'),
      );
      expect(
        await failing.retrieveResult(
          query: 'Priya',
          notebookId: 'nb',
          scope: RetrievalScope.user,
        ),
        same(MemoryRetrieval.empty),
      );

      final mismatched = RetrieveMemoryService.withInvoker(
        (_) async => {'version': 9},
      );
      expect(
        await mismatched.retrieveResult(
          query: 'Priya',
          notebookId: 'nb',
          scope: RetrievalScope.user,
        ),
        same(MemoryRetrieval.empty),
      );

      final slow = RetrieveMemoryService.withInvoker(
        (_) => Completer<dynamic>().future,
      );
      expect(
        await slow.retrieveResult(
          query: 'Priya',
          notebookId: 'nb',
          scope: RetrievalScope.user,
          timeout: const Duration(milliseconds: 10),
        ),
        same(MemoryRetrieval.empty),
      );
    });
  });

  test('user scope fails closed at 3.5 s by default; notebook scope waits',
      () {
    fakeAsync((async) {
      final pending = Completer<dynamic>();
      final service = RetrieveMemoryService.withInvoker((_) => pending.future);
      MemoryRetrieval? user;
      MemoryRetrieval? notebook;
      service
          .retrieveResult(
            query: 'Priya',
            notebookId: 'nb',
            scope: RetrievalScope.user,
          )
          .then((r) => user = r);
      service
          .retrieveResult(query: 'Priya', notebookId: 'nb', state: JournalState.empty())
          .then((r) => notebook = r);

      async.elapse(const Duration(milliseconds: 3400));
      expect(user, isNull);
      async.elapse(const Duration(milliseconds: 200));
      expect(user, same(MemoryRetrieval.empty));
      expect(notebook, isNull, reason: 'extraction keeps its old behaviour');

      pending.complete(_fixtureFor('retrieve-memory-v1.success.json'));
      async.flushMicrotasks();
      expect(notebook!.entityIds, ['maya', 'project-atlas']);
    });
  });

  group('memoryToolResult', () {
    // Friday 2026-10-23, local time.
    final now = DateTime(2026, 10, 23, 15);

    MemoryQuote quote({
      DateTime? spokenAt,
      required DateTime createdAt,
      String text = 'the CI fix is next',
    }) =>
        MemoryQuote(
          entryId: 'entry-secret-id',
          notebookId: 'notebook-secret-id',
          turnId: 'turn-secret-id',
          spokenAt: spokenAt,
          createdAt: createdAt,
          notebookTitle: 'Friday wrap-up',
          text: text,
        );

    test('gives the model context and dated quotes, never ids', () {
      final result = memoryToolResult(
        MemoryRetrieval(
          context: 'ctx',
          entityIds: const ['priya'],
          quotes: [
            quote(
              spokenAt: DateTime(2026, 10, 16, 17, 42),
              createdAt: DateTime(2026, 10, 16, 17, 43),
            ),
            quote(createdAt: DateTime(2026, 10, 22, 9), text: 'paired with Priya'),
          ],
        ),
        now: now,
      );

      expect(result, {
        'context': 'ctx',
        'quotes': [
          {'when': 'Fri, Oct 16 (last week)', 'text': 'the CI fix is next'},
          {'when': 'Thu, Oct 22 (yesterday)', 'text': 'paired with Priya'},
        ],
      });
      final encoded = jsonEncode(result);
      expect(encoded, isNot(contains('secret-id')));
      expect(encoded, isNot(contains('Friday wrap-up')));
    });

    test('empty retrieval gives empty context and no quotes', () {
      expect(memoryToolResult(MemoryRetrieval.empty, now: now), {
        'context': '',
        'quotes': <Map<String, String>>[],
      });
    });
  });
}
