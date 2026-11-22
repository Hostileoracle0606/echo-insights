import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/retrieve_memory_service.dart';

void main() {
  Map<String, dynamic> v3() => {
        'version': 3,
        'context': '',
        'entityIds': <String>[],
        'quotes': <dynamic>[],
        'verdict': {
          'status': 'supported',
          'text': 'Your previous goal was 100.',
          'sourceIds': ['private-id']
        },
      };
  test('v3 forwards only the verdict to Live', () {
    final result = MemoryRetrieval.fromData(v3());
    expect(memoryToolResult(result),
        {'status': 'supported', 'answer': 'Your previous goal was 100.'});
    expect(memoryToolResult(result).toString(), isNot(contains('private-id')));
  });
  test('a verdict with quotes also forwards them, dated, never ids', () {
    final data = v3();
    data['verdict'] = {
      'status': 'supported',
      'text': 'These are the user\'s own words about this.',
      'sourceIds': ['private-id']
    };
    data['quotes'] = [
      {
        'entryId': 'private-id',
        'notebookId': 'private-notebook',
        'notebookTitle': '',
        'turnId': null,
        'spokenAt': null,
        'createdAt': '2026-10-22T09:00:00Z',
        'text': 'My sister Priya is moving to Lisbon next month.',
      }
    ];
    final result = memoryToolResult(MemoryRetrieval.fromData(data),
        now: DateTime(2026, 10, 23, 15));
    expect(result['status'], 'supported');
    expect(result['quotes'], [
      {
        'when': 'Thu, Oct 22 (yesterday)',
        'text': 'My sister Priya is moving to Lisbon next month.'
      }
    ]);
    expect(result.toString(), isNot(contains('private')));
  });
  test('malformed and oversized v3 verdicts are rejected', () {
    final bad = v3();
    bad['verdict'] = {'status': 'unknown', 'text': 'x', 'sourceIds': []};
    expect(() => MemoryRetrieval.fromData(bad), throwsFormatException);
    final many = v3();
    many['quotes'] = [1, 2, 3, 4];
    expect(() => MemoryRetrieval.fromData(many), throwsFormatException);
  });
  test('user scope uses the opt-in contract and fails closed on timeout',
      () async {
    Map<String, dynamic>? sent;
    final service = RetrieveMemoryService.withInvoker((body) async {
      sent = body;
      return v3();
    });
    final result = await service.retrieveResult(
        query: 'goal',
        question: 'What was my previous goal?',
        notebookId: 'n',
        scope: RetrievalScope.user);
    if (memoryQueryRoutingEnabled) {
      expect(sent!['version'], 3);
      expect(sent!['question'], 'What was my previous goal?');
      expect(result.verdict?.status, 'supported');
      final slow =
          RetrieveMemoryService.withInvoker((_) => Completer<dynamic>().future);
      final fallback = await slow.retrieveResult(
          query: 'goal',
          question: 'What was my goal?',
          notebookId: 'n',
          scope: RetrievalScope.user,
          timeout: const Duration(milliseconds: 1));
      expect(fallback.verdict?.status, 'insufficient_evidence');
    } else {
      expect(sent!.containsKey('version'), isFalse);
      expect(sent!.containsKey('question'), isFalse);
    }
  });
}
