// Prototypes of faster data structures for the hot paths, each checked for
// identical output against the code the app ran before the fixes, then timed.
//
// Run: flutter test test/perf/dsa_alternatives_test.dart --reporter expanded
//
// These are the audit's prototypes (docs/complexity-audit.md). The fixes now
// in the app are in docs/performance-fixes.md; "before" here is the original
// code, kept verbatim under test/support/.
@Tags(['perf'])
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/entity_highlighter.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';

import '../support/legacy_agenda.dart';
import '../support/legacy_highlighter.dart';
import 'latency_bench_test.dart' show bench, syntheticState;

// ── 1. Bridge candidates: all-pairs → common-neighbour counting ────────────
//
// Today (agenda.dart): for every pair (a, b) of connected entities, build a
// sorted string key, check direct links, intersect neighbour sets, then sort
// every bridge found. O(V'^2 · d) time, O(V'^2) garbage strings.
//
// Alternative: a pair (a, b) shares neighbour m exactly when both are in
// N(m). So walk each middle node m and count every pair of its neighbours
// ("wedges"): O(sum of deg(m)^2) — linear-ish for a sparse graph — and keep
// only the top 6 with a bounded selection instead of sorting everything.
// Ties are broken by the original (i, j) pair order, so the result is equal.
List<(String, String)> bridgesByWedges(JournalState state) {
  final active = state.relations.values.where((r) => r.isActive);
  final neighbors = <String, Set<String>>{};
  for (final r in active) {
    neighbors.putIfAbsent(r.source, () => {}).add(r.target);
    neighbors.putIfAbsent(r.target, () => {}).add(r.source);
  }
  final ids = neighbors.keys.toList();
  final index = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  // Pair key = i * n + j with i < j, so no string building at all.
  final n = ids.length;
  final shared = <int, int>{};
  for (final m in neighbors.values) {
    final around = [for (final x in m) index[x]!]..sort();
    for (var p = 0; p < around.length; p++) {
      for (var q = p + 1; q < around.length; q++) {
        final key = around[p] * n + around[q];
        shared[key] = (shared[key] ?? 0) + 1;
      }
    }
  }
  // buildAgenda sorts its bridges with Dart's List.sort, which is not stable,
  // so equal-count ties come out in whatever order that sort leaves them. To
  // prove the counting is exact, feed the same list, in the same (i, j)
  // order, through the same sort. key = i * n + j orders by (i, j).
  final keys = shared.keys.toList()..sort();
  final bridges = <({String a, String b, int shared})>[
    for (final key in keys)
      if (!neighbors[ids[key ~/ n]]!.contains(ids[key % n]))
        (a: ids[key ~/ n], b: ids[key % n], shared: shared[key]!),
  ]..sort((x, y) => y.shared.compareTo(x.shared));
  return [
    for (final bridge in bridges.take(6))
      (
        state.entities[bridge.a]?.name ?? bridge.a,
        state.entities[bridge.b]?.name ?? bridge.b,
      ),
  ];
}

/// The recommended form: a deterministic tie-break (more shared neighbours
/// first, then pair order) and a bounded top-6, so no full sort is needed.
List<(String, String)> bridgesByWedgesTopK(JournalState state) {
  final active = state.relations.values.where((r) => r.isActive);
  final neighbors = <String, Set<String>>{};
  for (final r in active) {
    neighbors.putIfAbsent(r.source, () => {}).add(r.target);
    neighbors.putIfAbsent(r.target, () => {}).add(r.source);
  }
  final ids = neighbors.keys.toList();
  final index = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  final n = ids.length;
  final shared = <int, int>{};
  for (final m in neighbors.values) {
    final around = [for (final x in m) index[x]!]..sort();
    for (var p = 0; p < around.length; p++) {
      for (var q = p + 1; q < around.length; q++) {
        final key = around[p] * n + around[q];
        shared[key] = (shared[key] ?? 0) + 1;
      }
    }
  }
  final best = <(int, int)>[];
  int compare((int, int) x, (int, int) y) =>
      x.$1 != y.$1 ? y.$1.compareTo(x.$1) : x.$2.compareTo(y.$2);
  shared.forEach((key, count) {
    if (neighbors[ids[key ~/ n]]!.contains(ids[key % n])) return;
    final item = (count, key);
    if (best.length == 6 && compare(item, best.last) >= 0) return;
    best.add(item);
    best.sort(compare);
    if (best.length > 6) best.removeLast();
  });
  return [
    for (final (_, key) in best)
      (state.entities[ids[key ~/ n]]?.name ?? ids[key ~/ n],
          state.entities[ids[key % n]]?.name ?? ids[key % n]),
  ];
}

// ── 2. Relation count per entity: per-entity scan → one degree map ─────────
//
// Today (_buildGraphSummary): for each entity, scan every relation. O(V · R).
// Alternative: one pass over relations into a map. O(V + R).
Map<String, int> relationCountsScan(JournalState s) => {
      for (final e in s.entities.values)
        e.id: s.relations.values
            .where((r) => r.isActive && (r.source == e.id || r.target == e.id))
            .length,
    };

Map<String, int> relationCountsDegreeMap(JournalState s) {
  final degree = <String, int>{for (final e in s.entities.values) e.id: 0};
  for (final r in s.relations.values) {
    if (!r.isActive) continue;
    if (degree.containsKey(r.source)) degree[r.source] = degree[r.source]! + 1;
    if (r.target != r.source && degree.containsKey(r.target)) {
      degree[r.target] = degree[r.target]! + 1;
    }
  }
  return degree;
}

// ── 3. Transcript highlighting: one regex per entity → one pass ────────────
//
// Today (highlightRuns): sort all terms, then run one compiled regex per term
// over the text. O(V log V + V · |text|) per turn, per rebuild.
//
// Alternative: a trie of the lower-cased terms, walked from each word start.
// O(|text| · longest term) per turn, independent of V, built once per term
// set. Same rules: whole word on both sides, case-insensitive, and terms are
// applied longest first, so the longer of two overlapping mentions wins.
// Text whose lower-casing changes length (rare Unicode) falls back to the
// regex path, so indices never drift.
class _Node {
  final Map<int, _Node> next = {};
  int term = -1; // index into the length-sorted term list
}

class TermMatcher {
  TermMatcher(Iterable<HighlightTerm> terms)
      : sorted = terms.where((t) => t.text.isNotEmpty).toList()
          ..sort((a, b) => b.text.length.compareTo(a.text.length)) {
    for (var i = 0; i < sorted.length; i++) {
      var node = _root;
      for (final unit in sorted[i].text.toLowerCase().codeUnits) {
        node = node.next.putIfAbsent(unit, _Node.new);
      }
      if (node.term == -1) node.term = i; // first (longest-order) wins
    }
  }

  final List<HighlightTerm> sorted;
  final _Node _root = _Node();
  static final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  bool _isWord(String text, int i) =>
      i >= 0 && i < text.length && _wordChar.hasMatch(text[i]);

  List<TextRun> runs(String text) {
    if (text.isEmpty) return const [];
    final lower = text.toLowerCase();
    if (lower.length != text.length) return referenceRuns(text, sorted);
    // Every whole-word match: (term index, start, end).
    final found = <(int, int, int)>[];
    final units = lower.codeUnits;
    for (var start = 0; start < units.length; start++) {
      if (_isWord(text, start - 1) && _isWord(text, start)) continue;
      var node = _root;
      for (var i = start; i < units.length; i++) {
        final step = node.next[units[i]];
        if (step == null) break;
        node = step;
        if (node.term != -1 && !_isWord(text, i + 1) &&
            !(_isWord(text, start - 1))) {
          found.add((node.term, start, i + 1));
        }
      }
    }
    // Apply in the original order: longest term first, then left to right.
    found.sort((x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2));
    final taken = List<bool>.filled(text.length, false);
    final hits = <(int, int, EntityType)>[];
    for (final (term, s, e) in found) {
      var free = true;
      for (var i = s; i < e; i++) {
        if (taken[i]) {
          free = false;
          break;
        }
      }
      if (!free) continue;
      for (var i = s; i < e; i++) {
        taken[i] = true;
      }
      hits.add((s, e, sorted[term].type));
    }
    if (hits.isEmpty) return [TextRun(text)];
    hits.sort((a, b) => a.$1.compareTo(b.$1));
    final out = <TextRun>[];
    var at = 0;
    for (final (s, e, type) in hits) {
      if (s > at) out.add(TextRun(text.substring(at, s)));
      out.add(TextRun(text.substring(s, e), type));
      at = e;
    }
    if (at < text.length) out.add(TextRun(text.substring(at)));
    return out;
  }
}

String _fmt(List<TextRun> runs) =>
    runs.map((r) => r.type == null ? r.text : '[${r.text}|${r.type!.name}]').join();

void main() {
  test('bridges: same top 6 as buildAgenda, then timed', () {
    for (final seed in [1, 2, 3, 4, 5]) {
      for (final n in [30, 120, 400]) {
        final state = syntheticState(n, seed: seed);
        expect(bridgesByWedges(state), legacyBuildAgenda(state).bridgeCandidates,
            reason: 'seed $seed, n $n');
      }
    }
    for (final n in [200, 1000]) {
      final state = syntheticState(n);
      final before = bench('bridges_all_pairs (buildAgenda total)', n, () => legacyBuildAgenda(state));
      final after = bench('bridges_wedges (same output)', n, () => bridgesByWedges(state));
      final topK = bench('bridges_wedges_topk (deterministic ties)', n, () => bridgesByWedgesTopK(state));
      // ignore: avoid_print
      print('PERF bridges n=$n speedup≈${(before / after).toStringAsFixed(1)}x same-output, '
          '${(before / topK).toStringAsFixed(1)}x top-k '
          '(buildAgenda also does its other O(V+R+N) work)');
    }
  });

  test('relation counts: same map, then timed', () {
    for (final n in [50, 400]) {
      final state = syntheticState(n, seed: 9);
      expect(relationCountsDegreeMap(state), relationCountsScan(state));
    }
    for (final n in [200, 1000]) {
      final state = syntheticState(n);
      final before = bench('relation_counts_scan', n, () => relationCountsScan(state));
      final after = bench('relation_counts_degree_map', n, () => relationCountsDegreeMap(state));
      // ignore: avoid_print
      print('PERF relation_counts n=$n speedup≈${(before / after).toStringAsFixed(0)}x');
    }
  });

  test('highlighting: same runs as highlightRuns, then timed', () {
    final terms = [
      const HighlightTerm('Tidepool', EntityType.project),
      const HighlightTerm('Tidepool launch', EntityType.event),
      const HighlightTerm('Maya', EntityType.person),
      const HighlightTerm('CI', EntityType.project),
      const HighlightTerm('Café Lune', EntityType.place),
    ];
    final matcher = TermMatcher(terms);
    for (final text in [
      'Maya said the Tidepool launch slipped. maya agreed; tidepool is fine.',
      'MCI isn’t CI. CI-fix landed (CI). Café Lune at 9.',
      'No names here at all.',
      'Tidepool launchpad and Tidepool, launch!',
    ]) {
      expect(_fmt(matcher.runs(text)), _fmt(referenceRuns(text, terms)), reason: text);
    }
    for (final n in [200, 1000]) {
      final entityTerms = [
        for (var i = 0; i < n; i++) HighlightTerm('Entity $i', EntityType.values[i % 9]),
      ];
      final m = TermMatcher(entityTerms);
      const turn = 'Yesterday I met Entity 12 and Entity 340 near the office, '
          'then talked about Entity 7 for a while before heading home.';
      expect(_fmt(m.runs(turn)), _fmt(referenceRuns(turn, entityTerms)));
      final before = bench('highlight_regex_per_term', n, () => referenceRuns(turn, entityTerms));
      final after = bench('highlight_trie_one_pass', n, () => m.runs(turn));
      // ignore: avoid_print
      print('PERF highlight n=$n speedup≈${(before / after).toStringAsFixed(0)}x per turn');
    }
  });

  test('random graphs: bridges stay identical under heavy ties', () {
    final random = Random(42);
    for (var round = 0; round < 20; round++) {
      final state = syntheticState(10 + random.nextInt(60), seed: random.nextInt(1 << 30));
      expect(bridgesByWedges(state), legacyBuildAgenda(state).bridgeCandidates);
    }
  });
}
