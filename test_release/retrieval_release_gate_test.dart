// Host-side Flutter integration test. Run via scripts/retrieval-release-gate.mjs.
// Privileged configuration comes from process environment, never app defines.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/services/extraction_context.dart';
import 'package:lumen/services/retrieve_memory_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _stages = [
  'configuration',
  'deployment',
  'authentication',
  'migrations_and_seed',
  'lexical_retrieval',
  'embedding_generation',
  'semantic_retrieval',
  'flutter_consumption',
  'unauthorized_notebook',
  'cleanup',
];

void main() {
  test('deployed retrieval is safe and consumable by Flutter', () async {
    final results = {for (final stage in _stages) stage: 'blocked'};
    final env = Platform.environment;
    final clients = <SupabaseClient>[];
    final createdUsers = <String>[];
    SupabaseClient? admin;
    late SupabaseClient owner;
    late SupabaseClient outsider;
    late String url;
    late String publicKey;
    late String notebookId;
    late String ownerId;
    const semanticId = 'semantic-fixture';
    const lexicalId = 'lexical-only-fixture';
    const distractorId = 'unrelated-fixture';
    const query = 'Repairing a bicycle puncture by replacing the inner tube';
    final now = DateTime.now().toUtc();
    Entity entity(String id, String name) => Entity(
          id: id,
          name: name,
          type: EntityType.project,
          metadata: const {},
          mentions: 1,
          firstSeen: now,
          lastSeen: now,
        );
    // Opaque name and no description/relations/entries: query cannot match
    // semanticId lexically. Only its real stored embedding can retrieve it.
    final semanticState = JournalState.empty().copyWith(entities: {
      semanticId: entity(semanticId, 'Qzvrax'),
      distractorId: entity(distractorId, 'Xjpwzx'),
    });
    // This sentinel has no stored embedding and cannot be reached by graph
    // expansion. Returning it proves the lexical path independently.
    final lexicalState = JournalState.empty().copyWith(entities: {
      lexicalId: entity(lexicalId, 'Velomark'),
      distractorId: entity(distractorId, 'Xjpwzx'),
    });
    MemoryRetrieval? semanticResult;

    Future<bool> stage(String name, Future<void> Function() action) async {
      try {
        // Avoid advancing/cleaning fixtures while a timed-out mutation keeps
        // running. HTTP probes and the overall test/runner have deadlines.
        await action();
        results[name] = 'passed';
        return true;
      } catch (_) {
        // SDK errors can include response content. Report only stage names.
        results[name] = 'failed';
        return false;
      }
    }

    Future<Map<String, dynamic>> rawRetrieve(
      SupabaseClient client,
      JournalState state,
      String text,
    ) async {
      final response = await client.functions.invoke('retrieve-memory', body: {
        'query': text,
        'notebookId': notebookId,
        'state': stateToGraphloop(state),
      });
      expect(response.status, 200);
      final data = response.data;
      expect(data, isA<Map<String, dynamic>>());
      final map = data as Map<String, dynamic>;
      expect(map['context'], isA<String>());
      expect(map['entityIds'], isA<List>());
      expect((map['entityIds'] as List).every((id) => id is String), isTrue);
      return map;
    }

    try {
      final configured = await stage('configuration', () async {
        expect(env['RETRIEVAL_GATE_TARGET'], anyOf('local', 'staging'));
        for (final name in [
          'SUPABASE_URL',
          'SUPABASE_ANON_KEY',
          'SUPABASE_SERVICE_ROLE_KEY',
          'EMBED_INTERNAL_SECRET',
          'RETRIEVAL_GATE_REPORT',
        ]) {
          expect(env[name]?.isNotEmpty, isTrue);
        }
        url = env['SUPABASE_URL']!.replaceFirst(RegExp(r'/$'), '');
        final uri = Uri.parse(url);
        expect(uri.hasAuthority, isTrue);
        if (env['RETRIEVAL_GATE_TARGET'] == 'local') {
          expect(uri.host, anyOf('localhost', '127.0.0.1', '::1'));
        } else {
          expect(uri.scheme, 'https');
        }
        publicKey = env['SUPABASE_ANON_KEY']!;
      });
      if (!configured) return;

      final deployed = await stage('deployment', () async {
        final response = await http
            .post(
              Uri.parse('$url/functions/v1/retrieve-memory'),
              headers: {
                'apikey': publicKey,
                'content-type': 'application/json'
              },
              body: '{}',
            )
            .timeout(const Duration(seconds: 20));
        // A missing route (404), runtime import failure (5xx), or open function
        // (200) must not masquerade as successful deployment.
        expect(response.statusCode, 401);
      });

      final authenticated = await stage('authentication', () async {
        SupabaseClient client(String key) {
          final result = SupabaseClient(url, key,
              authOptions: const AuthClientOptions(autoRefreshToken: false));
          clients.add(result);
          return result;
        }

        admin = client(env['SUPABASE_SERVICE_ROLE_KEY']!);
        owner = client(publicKey);
        outsider = client(publicKey);
        final random = Random.secure();
        for (final userClient in [owner, outsider]) {
          final suffix =
              List.generate(24, (_) => random.nextInt(16).toRadixString(16))
                  .join();
          final email = 'retrieval-gate-$suffix@example.test';
          final password = 'Gate-$suffix-Aa1!';
          final created =
              await admin!.auth.admin.createUser(AdminUserAttributes(
            email: email,
            password: password,
            emailConfirm: true,
          ));
          expect(created.user, isNotNull);
          createdUsers.add(created.user!.id);
          final signedIn = await userClient.auth.signInWithPassword(
            email: email,
            password: password,
          );
          expect(signedIn.session?.accessToken.isNotEmpty, isTrue);
          expect(signedIn.user?.id, created.user!.id);
        }
        ownerId = owner.auth.currentUser!.id;
      });
      if (!authenticated) return;

      final seeded = await stage('migrations_and_seed', () async {
        final notebook = await admin!
            .from('notebooks')
            .insert({
              'user_id': ownerId,
              'title': 'Retrieval release gate',
              'started_at': now.toIso8601String(),
            })
            .select('id')
            .single();
        notebookId = notebook['id'] as String;
        await admin!.from('entities').insert({
          'id': semanticId,
          'user_id': ownerId,
          'notebook_id': notebookId,
          'name': 'Qzvrax',
          'type': 'project',
          'description': query,
          'first_seen': now.toIso8601String(),
          'last_seen': now.toIso8601String(),
        });
        // Check migration availability independently of the function's fallback.
        expect(
            await owner.rpc('bump_retrieve_rate', params: {
              'p_notebook_id': notebookId,
            }),
            isTrue);
        await admin!
            .from('entity_embeddings')
            .select('entity_id')
            .eq('notebook_id', notebookId);
        final vector = [1, ...List.filled(383, 0)];
        await admin!.rpc('match_entity_embeddings', params: {
          'p_notebook_id': notebookId,
          'p_query': jsonEncode(vector),
          'p_limit': 1,
          'p_model': 'gte-small@1',
        });
      });
      if (!seeded || !deployed) return;

      await stage('lexical_retrieval', () async {
        final data = await rawRetrieve(owner, lexicalState, 'Velomark');
        expect(data['entityIds'], contains(lexicalId));
        expect(data['entityIds'], isNot(contains(distractorId)));
        expect(data['context'], isNotEmpty);
      });

      final embedded = await stage('embedding_generation', () async {
        final response = await http
            .post(
              Uri.parse('$url/functions/v1/embed-entities'),
              headers: {
                'apikey': publicKey,
                'content-type': 'application/json',
                'x-internal-secret': env['EMBED_INTERNAL_SECRET']!,
              },
              body: jsonEncode({'notebookId': notebookId}),
            )
            .timeout(const Duration(seconds: 60));
        expect(response.statusCode, 200);
        expect((jsonDecode(response.body) as Map)['ok'], isTrue);
        final row = await admin!
            .from('entity_embeddings')
            .select('embedding_model,embedding')
            .eq('notebook_id', notebookId)
            .eq('entity_id', semanticId)
            .single();
        expect(row['embedding_model'], 'gte-small@1');
        final vector = row['embedding'] is String
            ? jsonDecode(row['embedding'] as String)
            : row['embedding'];
        expect(vector, hasLength(384));
      });

      if (embedded) {
        await stage('semantic_retrieval', () async {
          final data = await rawRetrieve(owner, semanticState, query);
          expect(data['entityIds'], contains(semanticId));
          expect(data['entityIds'], isNot(contains(distractorId)));
          expect(data['context'], isNotEmpty);
        });
        await stage('flutter_consumption', () async {
          semanticResult = await RetrieveMemoryService(owner).retrieveResult(
            query: query,
            notebookId: notebookId,
            state: semanticState,
          );
          // Fail-closed empty results explicitly fail this gate.
          expect(semanticResult!.entityIds, contains(semanticId));
          expect(semanticResult!.entityIds, isNot(contains(distractorId)));
          expect(semanticResult!.context, isNotEmpty);
          final context = compileExtractionContext(
            transcript: query,
            state: semanticState,
            retrievedEntityIds: semanticResult!.entityIds,
            recentTurns: const [],
          );
          expect(context.entities.map((entity) => entity.id),
              contains(semanticId));
          expect(
              buildExtractionUserMessage(query, context), contains('Qzvrax'));
          final withoutRetrieval = compileExtractionContext(
            transcript: query,
            state: semanticState,
            retrievedEntityIds: const [],
            recentTurns: const [],
          );
          expect(withoutRetrieval.entities, isEmpty);
        });
      }

      await stage('unauthorized_notebook', () async {
        // Raw status required: the production adapter masks errors as empty.
        final response = await http
            .post(
              Uri.parse('$url/functions/v1/retrieve-memory'),
              headers: {
                'apikey': publicKey,
                'content-type': 'application/json',
                'authorization':
                    'Bearer ${outsider.auth.currentSession!.accessToken}',
              },
              body: jsonEncode({
                'query': query,
                'notebookId': notebookId,
                'state': stateToGraphloop(semanticState),
              }),
            )
            .timeout(const Duration(seconds: 20));
        expect(response.statusCode, 404);
        expect(jsonDecode(response.body), {'error': 'notebook not found'});
      });
    } finally {
      await stage('cleanup', () async {
        var failed = false;
        for (final id in createdUsers.reversed) {
          try {
            // Only this run's users; FK cascades remove their fixture data.
            await admin!.auth.admin.deleteUser(id);
          } catch (_) {
            failed = true;
          }
        }
        for (final client in clients) {
          await client.dispose();
        }
        expect(failed, isFalse);
      });
      final passed = results.values.every((result) => result == 'passed');
      final report = {
        'version': 1,
        'passed': passed,
        'finishedAt': DateTime.now().toUtc().toIso8601String(),
        'stages': results,
      };
      final reportPath = env['RETRIEVAL_GATE_REPORT'];
      if (reportPath != null) {
        File(reportPath).writeAsStringSync('${jsonEncode(report)}\n');
      }
      // Counts/statuses only; no queries, credentials, user IDs or responses.
      // ignore: avoid_print
      print(jsonEncode(report));
      expect(passed, isTrue, reason: 'Retrieval release gate failed: $results');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
