// LM-56 extraction quality, measured through the app's real code path.
//
//   flutter test tool/spike_pseudonymization/lm56_measure_test.dart
//   node tool/spike_pseudonymization/lm56_score.mjs
//
// For each spike transcript (fixtures/, synthetic): the graph goes into the
// real PseudonymService (map on this isolate; no NLTagger in a test, so only
// names the graph knows are swapped), the real ExtractGraphService builds
// and swaps the request, the real extract-graph handler (lm56_lambda.mjs, run
// with node) builds the prompt and calls gemini-2.5-flash, and the patch is
// swapped back by the app's code. Patches land in lm56_results/ for
// lm56_score.mjs, which scores them with the spike's metric code.
//
// Not part of `flutter test` (which runs test/ only).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumen/logic/slugify.dart';
import 'package:lumen/logic/turn_state.dart' show Speaker;
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/extract_graph_service.dart';
import 'package:lumen/services/pseudonym_service.dart';
import 'package:lumen/services/pseudonym_store.dart';
import 'package:lumen/services/pseudonym_worker.dart';

const _dir = 'tool/spike_pseudonymization';
const _notebookId = '8e03b8f4-4f20-4df3-8398-d854adc32b14';

class _Store implements PseudonymStore {
  String? saved;
  @override
  Future<String?> read() async => saved;
  @override
  Future<void> write(String json) async => saved = json;
  @override
  Future<void> delete() async => saved = null;
}

/// The app's request goes to the real handler, run by node.
class _LambdaClient extends http.BaseClient {
  _LambdaClient(this.tag);
  final String tag;
  final rawBodies = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    final process = await Process.start(
      'node',
      ['$_dir/lm56_lambda.mjs'],
      environment: {'LM56_TAG': tag},
    );
    process.stdin.write(jsonEncode({'notebookId': _notebookId, 'body': body}));
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    await process.stderr.drain<void>();
    await process.exitCode;
    final response = jsonDecode(out) as Map<String, dynamic>;
    final responseBody = response['body'] as String;
    rawBodies.add(responseBody);
    return http.StreamedResponse(
      Stream.value(utf8.encode(responseBody)),
      response['statusCode'] as int,
      headers: {'content-type': 'application/json'},
    );
  }
}

Map<String, dynamic> _read(String name) =>
    jsonDecode(File('$_dir/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('LM-56 extraction through the real path', timeout: Timeout.none,
      () async {
    final graph = _read('entities.json');
    final transcripts = jsonDecode(
      File('$_dir/fixtures/transcripts.json').readAsStringSync(),
    ) as List;
    final now = DateTime.utc(2026, 11, 1);
    final byFixtureId = <String, Entity>{};
    for (final raw in graph['entities'] as List) {
      final e = raw as Map<String, dynamic>;
      byFixtureId[e['id'] as String] = Entity(
        id: slugify(e['name'] as String),
        name: e['name'] as String,
        type: EntityType.values.byName(e['type'] as String),
        description: e['description'] as String?,
        metadata: {
          'aliases': e['aliases'],
          if (e['gender'] != null) 'gender': e['gender'],
          if (e['role'] != null) 'role': e['role'],
        },
        mentions: 1,
        firstSeen: now,
        lastSeen: now,
      );
    }
    final relations = <String, Relation>{};
    for (final raw in graph['relations'] as List) {
      final r = raw as Map<String, dynamic>;
      final source = byFixtureId[r['source']]!;
      final target = byFixtureId[r['target']]!;
      final id = relationId(source.name, r['label'] as String, target.name);
      relations[id] = Relation(
        id: id,
        source: source.id,
        target: target.id,
        label: r['label'] as String,
        metadata: const {},
        createdAt: now,
      );
    }
    final state = JournalState.empty().copyWith(
      entities: {for (final e in byFixtureId.values) e.id: e},
      relations: relations,
    );

    final store = _Store();
    final pseudonyms = PseudonymService(
      ownerId: () => 'measure-user',
      store: store,
      host: InlinePseudonymHost(),
    );

    final results = <Map<String, dynamic>>[];
    for (final raw in transcripts) {
      final t = raw as Map<String, dynamic>;
      final id = t['id'] as String;
      final client = _LambdaClient('$id-lm56');
      final service = ExtractGraphService(
        baseUrl: 'https://measure.invalid',
        accessTokenProvider: () async => 'measure',
        pseudonyms: pseudonyms,
        client: client,
      );
      final row = <String, dynamic>{'transcript': id};
      try {
        final patch = await service.extract(
          notebookId: _notebookId,
          turnId: 'measure-$id',
          extractorVersion: 'gemini/extract_graph/v2',
          text: t['text'] as String,
          state: state,
          mode: 'granular',
          recentConversation: [
            for (final turn in t['recent'] as List)
              (
                role: Speaker.values.byName(turn['role'] as String),
                text: turn['text'] as String,
              ),
          ],
          retrievedEntityIds: state.entities.keys.toList(),
          maxRetries: 0,
        );
        row['patch'] = patch.toJson();
      } catch (error) {
        row['error'] = error.runtimeType.toString();
      }
      // Stand-ins the map issued, to count any left in the swapped-back
      // patch (the spike's "swap-back" criterion).
      final map = jsonDecode(store.saved ?? '{"entries":[]}') as Map;
      row['standIns'] = <String>{
        for (final e in map['entries'] as List) ...[
          e['fake'] as String,
          ...(e['fakes'] as Map).values.cast<String>(),
        ],
      }.toList();
      row['rawResponses'] = client.rawBodies;
      results.add(row);
    }
    Directory('$_dir/lm56_results').createSync(recursive: true);
    File('$_dir/lm56_results/patches.json').writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert(results),
    );
  });
}
