// SupabaseService.deleteAccount: server delete first, then the local
// transcript journal, then the session. A failed server call leaves the
// journal and the session in place.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/services/supabase_service.dart';
import 'package:lumen/services/turn_journal_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

FinalizedTurn _turn() => FinalizedTurn(
      turnId: 'turn-1',
      sessionId: 'session-1',
      notebookId: 'notebook-1',
      speaker: Speaker.user,
      transcript: 'A verbatim transcript.',
      transcriptVersion: 1,
      transcriptHash: 'hash-1',
      extractorVersion: 'extractor-1',
      generation: 1,
      commitRequestId: 'request-1',
      stage: DurableStage.finalRecorded,
      finalizedAt: '2026-09-22T12:00:00.000Z',
    );

void main() {
  late Directory directory;
  late TurnJournalService journal;
  late List<http.Request> requests;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lumen-delete-account-');
    journal = TurnJournalService(directoryProvider: () async => directory);
    await journal.persistTurn(_turn());
    requests = [];
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  SupabaseService serviceReturning(int status) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', status,
            headers: {'content-type': 'application/json'});
      }),
    );
    return SupabaseService(client);
  }

  test('calls delete-account, then clears the local journal', () async {
    await serviceReturning(200).deleteAccount(journal: journal);

    expect(requests.map((r) => '${r.method} ${r.url.path}'),
        contains('POST /functions/v1/delete-account'));
    // Only the verified JWT identifies the account; no body is sent.
    expect(
      requests.firstWhere((r) => r.url.path.endsWith('delete-account')).body,
      isEmpty,
    );
    expect(
      await Directory('${directory.path}/turn-journal-v1').exists(),
      isFalse,
    );
    expect(await journal.loadTurns('notebook-1'), isEmpty);
  });

  test('a failed server delete throws and keeps the local journal', () async {
    await expectLater(
      serviceReturning(500).deleteAccount(journal: journal),
      throwsA(isA<FunctionException>()),
    );
    expect(await journal.loadTurns('notebook-1'), hasLength(1));
  });
}
