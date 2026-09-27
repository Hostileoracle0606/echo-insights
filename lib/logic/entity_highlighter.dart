import '../models/entity.dart';

/// A name to mark wherever it is spoken, coloured by its entity type.
class HighlightTerm {
  final String text;
  final EntityType type;
  const HighlightTerm(this.text, this.type);
}

/// A slice of transcript text: marked when [type] is set.
class TextRun {
  final String text;
  final EntityType? type;
  const TextRun(this.text, [this.type]);
}

/// The graph's entities as highlight terms. One-letter names would light up
/// half the transcript, so they are left out.
List<HighlightTerm> termsForEntities(Iterable<Entity> entities) => [
      for (final e in entities)
        if (e.name.trim().length >= 2) HighlightTerm(e.name.trim(), e.type),
    ];

// Compiled once per distinct term: highlightRuns runs for every visible turn
// on every transcript chunk, and recompiling each entity's pattern there
// dominated its cost in large notebooks.
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

/// Splits [text] into runs, marking every whole-word, case-insensitive
/// mention of a term. Where mentions overlap the longest term wins, so
/// "Tidepool launch" beats "Tidepool". Joining the runs gives back [text].
List<TextRun> highlightRuns(String text, Iterable<HighlightTerm> terms) {
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
