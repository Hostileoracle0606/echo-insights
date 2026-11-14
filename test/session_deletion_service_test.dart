// LM-48 wire contract: delete_notebook. The RPC itself is proven against
// Postgres by supabase/tests/database/delete_notebook_test.sql.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/session_deletion_service.dart';

void main() {
  group('SessionDeletionService', () {
    late List<(String, Map<String, dynamic>)> calls;
    late Object? response;
    late SessionDeletionService service;

    setUp(() {
      calls = [];
      response = null;
      service = SessionDeletionService.withRpc((fn, params) async {
        calls.add((fn, params));
        return response;
      });
    });

    test('deleteSession calls delete_notebook with the notebook id', () async {
      response = {'deleted': true};

      final deleted = await service.deleteSession('nb-1');

      expect(deleted, isTrue);
      expect(calls.single.$1, 'delete_notebook');
      expect(calls.single.$2, {'p_notebook_id': 'nb-1'});
    });

    test('a session that is already gone is not an error', () async {
      response = {'deleted': false};

      expect(await service.deleteSession('nb-1'), isFalse);
    });

    test('an RPC failure is thrown to the caller', () async {
      service = SessionDeletionService.withRpc(
        (fn, params) async => throw StateError('network'),
      );

      expect(service.deleteSession('nb-1'), throwsStateError);
    });
  });
}
