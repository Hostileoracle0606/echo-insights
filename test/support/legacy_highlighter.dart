// The per-term regex highlighter from before the complexity fixes, kept
// verbatim as the reference for test/entity_highlighter_equivalence_test.dart
// and the before/after benchmark.
import 'package:lumen/logic/entity_highlighter.dart';
import 'package:lumen/models/entity.dart';

// The original's pattern cache, kept so timings compare like with like.
final Map<String, RegExp> _patterns = {};

RegExp _patternFor(String term) {
  final cached = _patterns[term];
  if (cached != null) return cached;
  if (_patterns.length > 4096) _patterns.clear();
  return _patterns[term] = RegExp(
    '(?<![\\p{L}\\p{N}])${RegExp.escape(term)}(?![\\p{L}\\p{N}])',
    caseSensitive: false,
    unicode: true,
  );
}

List<TextRun> referenceRuns(String text, Iterable<HighlightTerm> terms) {
  if (text.isEmpty) return const [];
  final sorted = terms.where((t) => t.text.isNotEmpty).toList()
    ..sort((a, b) => b.text.length.compareTo(a.text.length));
  final taken = List<bool>.filled(text.length, false);
  final hits = <({int start, int end, EntityType type})>[];
  for (final term in sorted) {
    for (final m in _patternFor(term.text).allMatches(text)) {
      var free = true;
      for (var i = m.start; i < m.end; i++) {
        if (taken[i]) {
          free = false;
          break;
        }
      }
      if (!free) continue;
      for (var i = m.start; i < m.end; i++) {
        taken[i] = true;
      }
      hits.add((start: m.start, end: m.end, type: term.type));
    }
  }
  if (hits.isEmpty) return [TextRun(text)];
  hits.sort((a, b) => a.start.compareTo(b.start));
  final runs = <TextRun>[];
  var at = 0;
  for (final hit in hits) {
    if (hit.start > at) runs.add(TextRun(text.substring(at, hit.start)));
    runs.add(TextRun(text.substring(hit.start, hit.end), hit.type));
    at = hit.end;
  }
  if (at < text.length) runs.add(TextRun(text.substring(at)));
  return runs;
}
