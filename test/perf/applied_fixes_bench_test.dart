// Before and after for the applied complexity fixes, on the same inputs.
//
// Run: flutter test test/perf/applied_fixes_bench_test.dart --reporter expanded
//
// "Before" is the original code, kept verbatim under test/support/; "after"
// is the app code. Both run on the synthetic notebooks the latency bench
// uses. Results print as `PERF` lines; docs/performance-fixes.md quotes them.
@Tags(['perf'])
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/agenda.dart';
import 'package:lumen/logic/entity_highlighter.dart';
import 'package:lumen/logic/graph_summary.dart';
import 'package:lumen/models/journal_state.dart';

import '../support/legacy_agenda.dart';
import '../support/legacy_highlighter.dart';
import 'latency_bench_test.dart' show bench, syntheticState;

void report(String name, int n, double before, double after) {
  // ignore: avoid_print
  print('PERF applied $name n=$n before=${before.toStringAsFixed(2)}ms '
      'after=${after.toStringAsFixed(3)}ms '
      'speedup≈${(before / max(after, 0.001)).toStringAsFixed(0)}x');
}

/// The graph summary as `_buildGraphSummary` built it before: the legacy
/// agenda, and each entity's relation count by scanning every relation.
Map<String, dynamic> legacySummary(JournalState state, String lastUserText) {
  final agenda = legacyBuildAgenda(state, lastUserText: lastUserText);
  final active = state.relations.values.where((r) => r.isActive).toList();
  return {
    'entities': [
      for (final e in state.entities.values)
        {
          'name': e.name,
          'relationCount':
              active.where((r) => r.source == e.id || r.target == e.id).length,
          'coverage': agenda.thinEntities.contains(e.name) ? 'thin' : 'developing',
        },
    ],
    'bridgeCandidates': agenda.bridgeCandidates,
  };
}

void main() {
  for (final n in [200, 1000]) {
    test('agenda, n=$n', () {
      final state = syntheticState(n);
      final before = bench('agenda_legacy', n, () => legacyBuildAgenda(state, lastUserText: 'Entity 3'));
      final after = bench('agenda_new', n, () => buildAgenda(state, lastUserText: 'Entity 3'));
      report('agenda', n, before, after);
      expect(after, lessThan(before));
    });

    test('graph summary body, n=$n', () {
      final state = syntheticState(n);
      final before = bench('summary_legacy', n, () => legacySummary(state, 'Entity 3'));
      final after = bench('summary_new', n, () => graphSummaryBody(state, lastUserText: 'Entity 3'));
      report('graph_summary', n, before, after);
      expect(after, lessThan(before));
    });

    test('highlighting one turn, n=$n terms', () {
      final state = syntheticState(n);
      final terms = [
        for (final e in state.entities.values) HighlightTerm(e.name, e.type),
      ];
      final text = List.generate(
        12,
        (i) => 'Then I told Entity ${i * 7} about Entity ${i * 13} and the plan.',
      ).join(' ');
      final before = bench('highlight_legacy', n, () => referenceRuns(text, terms));
      // Warm: the app passes the same terms list for every turn on screen.
      final warm = bench('highlight_new_warm', n, () => highlightRuns(text, terms));
      // Cold: a new list, so the trie is built inside the timing.
      final cold = bench('highlight_new_cold', n, () => highlightRuns(text, [...terms]));
      report('highlight_warm', n, before, warm);
      report('highlight_cold', n, before, cold);
      expect(warm, lessThan(before));
    });
  }
}
