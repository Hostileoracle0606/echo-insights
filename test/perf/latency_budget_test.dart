// The waits the app adds on purpose, pinned, plus the budget rules between
// them. A change to any of these moves what the user feels, so it should be
// a deliberate edit to this file, not a side effect.
//
// Run: flutter test test/perf/latency_budget_test.dart --reporter expanded
@Tags(['perf'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/conversation_policy.dart' as policy;
import 'package:lumen/providers/journal_provider.dart' show finalizationDeadlineMs;
import 'package:lumen/services/gemini_live_client.dart';
import 'package:lumen/services/retrieve_memory_service.dart'
    show userScopeRetrieveTimeout;

GeminiLiveClient _client() => GeminiLiveClient(
      sessionToken: 'token',
      model: 'model',
      systemInstruction: '',
      voice: 'voice',
      tools: const [],
    );

void main() {
  test('waits on the path from "user stops talking" to "Lumen answers"', () {
    final live = _client();
    // Gemini ends the user's turn after this much silence.
    expect(live.silenceToEndTurn, const Duration(milliseconds: 700));
    // A tool call never holds Lumen longer than this.
    expect(live.toolTimeout, const Duration(seconds: 4));
    // Recall must give up before the tool budget, leaving room to answer.
    expect(userScopeRetrieveTimeout < live.toolTimeout, isTrue);
    expect(live.toolTimeout - userScopeRetrieveTimeout,
        greaterThanOrEqualTo(const Duration(milliseconds: 300)));
    // ignore: avoid_print
    print('PERF budget reply: silence=${live.silenceToEndTurn.inMilliseconds}ms '
        'toolCap=${live.toolTimeout.inMilliseconds}ms '
        'recallCap=${userScopeRetrieveTimeout.inMilliseconds}ms');
  });

  test('waits before a user turn reaches extraction', () {
    // A finished turn without its final transcript waits this long.
    expect(finalizationDeadlineMs, 1500);
    // ignore: avoid_print
    print('PERF budget extraction: finalizationDeadline=${finalizationDeadlineMs}ms '
        '(only when Gemini sends turnComplete before the final transcript)');
  });

  test('the remaining policy constants are unused by the iPhone app', () {
    // Ported from the web app; nothing in lib/ reads them. If one starts
    // being used, it becomes a real wait and belongs in a test above.
    expect(policy.silenceFlushMs, 2000);
    expect(policy.endpointingMs, 1000);
    expect(policy.finalChunkDebounceMs, 1400);
    expect(policy.pauseDeferralMs, 900);
    expect(policy.sentenceIdleMs, 700);
  });
}
