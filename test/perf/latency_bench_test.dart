// On-device CPU cost of the work that sits on a latency-critical path.
//
// Run: flutter test test/perf/latency_bench_test.dart --reporter expanded
//
// Each case builds a synthetic notebook of a given size and times one piece
// of real app code over several runs. Results print as `PERF` lines (median
// and worst run, in ms). The expectations are loose ceilings that catch a
// regression without being flaky on a busy laptop; the printed numbers are
// the measurement. Host-VM timings understate an iPhone by roughly 2–4×.
@Tags(['perf'])
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/graph_summary.dart';
import 'package:lumen/logic/graph_layout.dart';
import 'package:lumen/logic/merge.dart' as merge_logic;
import 'package:lumen/logic/turn_state.dart' show Speaker;
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';
import 'package:lumen/models/journal_entry.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/models/relation.dart';
import 'package:lumen/services/extraction_context.dart';
import 'package:lumen/services/markdown_export.dart';
import 'package:lumen/services/retrieve_memory_service.dart';

const _sizes = [50, 200, 1000];

/// A notebook with [n] entities, about 1.5n relations and 2n entries.
JournalState syntheticState(int n, {int seed = 7}) {
  final random = Random(seed);
  final start = DateTime.utc(2026, 10, 1);
  const types = EntityType.values;
  final entities = <String, Entity>{
    for (var i = 0; i < n; i++)
      'e$i': Entity(
        id: 'e$i',
        name: 'Entity $i',
        type: types[i % types.length],
        description: i.isEven
            ? 'Entity $i is a ${types[i % types.length].name} the user '
                'talks about, with a short factual description.'
            : null,
        metadata: const {},
        mentions: 1 + random.nextInt(12),
        firstSeen: start.add(Duration(minutes: i)),
        lastSeen: start.add(Duration(hours: i)),
        questions: i % 3 == 0 ? ['What changed with Entity $i?'] : null,
      ),
  };
  final relations = <String, Relation>{};
  for (var i = 0; i < (n * 1.5).round(); i++) {
    final s = random.nextInt(n);
    var t = random.nextInt(n);
    if (t == s) t = (t + 1) % n;
    final id = 'e${s}__related_to__e$t';
    relations[id] = Relation(
      id: id,
      source: 'e$s',
      target: 'e$t',
      label: 'related_to',
      metadata: const {},
      createdAt: start,
    );
  }
  final relationIds = relations.keys.toList();
  final entries = [
    for (var i = 0; i < n * 2; i++)
      JournalEntry(
        id: 'j$i',
        text: 'I talked with Entity ${random.nextInt(n)} about '
            'Entity ${random.nextInt(n)} and how the week went overall.',
        createdAt: start.add(Duration(minutes: i * 3)),
        entityIds: ['e${random.nextInt(n)}', 'e${random.nextInt(n)}'],
        relationIds: [relationIds[random.nextInt(relationIds.length)]],
      ),
  ];
  return JournalState(
    entries: entries,
    entities: entities,
    relations: relations,
    followUps: const [],
  );
}

/// Times [body] [runs] times after one warm-up, prints a PERF line and
/// returns the median in milliseconds.
double bench(String name, int size, void Function() body, {int runs = 9}) {
  body();
  final samples = <double>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    body();
    watch.stop();
    samples.add(watch.elapsedMicroseconds / 1000);
  }
  samples.sort();
  final median = samples[samples.length ~/ 2];
  // ignore: avoid_print
  print('PERF $name n=$size median=${median.toStringAsFixed(2)}ms '
      'worst=${samples.last.toStringAsFixed(2)}ms');
  return median;
}

/// The get_graph_summary answer as the app builds it (the notebook-derived
/// part; the notifier adds two small conversation fields).
Map<String, dynamic> graphSummaryLike(JournalState state) =>
    graphSummaryBody(state, lastUserText: 'Entity 3 and Entity 9');

void main() {
  group('tool answers Gemini waits on', () {
    for (final n in _sizes) {
      test('get_graph_summary answer, n=$n', () {
        final state = syntheticState(n);
        late String encoded;
        final ms = bench('graph_summary_build+encode', n, () {
          encoded = jsonEncode(graphSummaryLike(state));
        });
        // Payload size drives Gemini's input-token cost on every call.
        // ignore: avoid_print
        print('PERF graph_summary_payload n=$n bytes=${encoded.length} '
            'approxTokens=${(encoded.length / 4).round()}');
        expect(ms, lessThan(n <= 200 ? 50 : 2000));
      });
    }
  });

  group('per-turn extraction path', () {
    for (final n in _sizes) {
      test('retrieval request body (notebook scope), n=$n', () {
        final state = syntheticState(n);
        late String body;
        final ms = bench('retrieve_body_encode', n, () {
          body = jsonEncode({
            'query': 'Entity 3 and the CI pipeline',
            'notebookId': 'nb',
            'state': stateToGraphloop(state),
          });
        });
        // ignore: avoid_print
        print('PERF retrieve_body_bytes n=$n bytes=${body.length}');
        expect(ms, lessThan(500));
      });

      test('extraction context compile, n=$n', () {
        final state = syntheticState(n);
        final turns = [
          for (var i = 0; i < 20; i++)
            (
              role: i.isEven ? Speaker.user : Speaker.assistant,
              text: 'Turn $i about Entity $i and what happened next.',
            ),
        ];
        final ms = bench('extraction_context', n, () {
          compileExtractionContext(
            transcript: 'I met Entity 4 and Entity 12 at the gym again.',
            state: state,
            retrievedEntityIds: const ['e4', 'e12'],
            recentTurns: turns,
          );
        });
        expect(ms, lessThan(500));
      });

      test('merge a patch into the notebook, n=$n', () {
        final state = syntheticState(n);
        final patch = GraphPatch.fromJson({
          'entities': [
            {'name': 'Entity 4', 'type': 'person', 'description': 'A friend.'},
            {'name': 'Brand new place', 'type': 'place'},
          ],
          'relations': [
            {
              'source': 'Entity 4',
              'target': 'Brand new place',
              'label': 'visited',
            },
          ],
          'supersedes': <String>[],
        });
        final ms = bench('merge_patch', n, () {
          merge_logic.merge(state, 'I met Entity 4 at a new place.', patch);
        });
        expect(ms, lessThan(500));
      });
    }
  });

  group('frame budget (16.7 ms at 60 fps)', () {
    for (final n in [50, 150, 300]) {
      test('graph layout step, n=$n', () {
        final state = syntheticState(n);
        final layout = GraphLayout(random: Random(1));
        for (final id in state.entities.keys) {
          layout.spawn(id, radius: 8, near: Offset.zero);
        }
        layout.links = [
          for (final r in state.relations.values) (r.source, r.target),
        ];
        final ms = bench('graph_layout_step', n, () {
          layout.reheat();
          layout.step();
        }, runs: 31);
        expect(ms, lessThan(n <= 150 ? 16.7 : 200));
      });
    }
  });

  group('after the conversation', () {
    for (final n in [200, 1000]) {
      test('Markdown vault build, n=$n', () {
        final state = syntheticState(n);
        final ms = bench('markdown_vault', n, () => buildVault(state), runs: 5);
        expect(ms, lessThan(n <= 200 ? 2000 : 20000));
      });
    }
  });
}
