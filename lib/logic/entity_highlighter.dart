import '../models/entity.dart';
import 'name_matcher.dart';

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

/// Splits [text] into runs, marking every whole-word, case-insensitive
/// mention of a term. Where mentions overlap the longest term wins, so
/// "Tidepool launch" beats "Tidepool". Joining the runs gives back [text].
///
/// Runs for every visible turn on every transcript chunk, so it must not
/// scale with the number of entities. The terms are compiled once into a
/// trie (cached per terms list) and the text is walked once: O(T · L) for
/// text length T and longest term L, instead of one regex pass per term.
List<TextRun> highlightRuns(String text, Iterable<HighlightTerm> terms) {
  if (text.isEmpty) return const [];
  final matcher = _matchers[terms] ??= _TermMatcher(terms);
  if (!matcher.fastPath || !_caseFoldsLikeLowercase(text)) {
    return _highlightRunsRegex(text, matcher.sorted);
  }
  return matcher.runs(text);
}

final Expando<_TermMatcher> _matchers = Expando('highlight matchers');

/// True when lower-casing [text] matches the regex engine's Unicode case
/// folding: Latin script up to U+024F, except the long s and the micro sign,
/// which fold to other letters. Elsewhere (Greek final sigma, the Kelvin
/// sign…) the two differ, so those texts take the regex path.
bool _caseFoldsLikeLowercase(String text) {
  for (final unit in text.codeUnits) {
    if (unit > 0x24F || unit == 0x17F || unit == 0xB5) return false;
  }
  return true;
}

final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isWordAt(String text, int i) =>
    i >= 0 && i < text.length && _wordChar.hasMatch(text[i]);

class _TermMatcher {
  _TermMatcher(Iterable<HighlightTerm> terms)
      : sorted = terms.where((t) => t.text.isNotEmpty).toList()
          ..sort((a, b) => b.text.length.compareTo(a.text.length)) {
    fastPath = sorted.every((t) => _caseFoldsLikeLowercase(t.text));
    trie = NameTrie(sorted.map((t) => t.text.toLowerCase()));
  }

  /// Longest first: the order terms claim text in.
  final List<HighlightTerm> sorted;
  late final bool fastPath;
  late final NameTrie trie;

  List<TextRun> runs(String text) {
    final units = text.toLowerCase().codeUnits;
    // Every whole-word match, as (term rank, start, end).
    final found = <(int, int, int)>[];
    for (var start = 0; start < units.length; start++) {
      if (_isWordAt(text, start - 1)) continue;
      trie.matchesFrom(units, start, (rank, end) {
        if (!_isWordAt(text, end)) found.add((rank, start, end));
      });
    }
    // Claim text in the same order as before: longest term first, then left
    // to right, skipping anything already claimed.
    found.sort((x, y) => x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2));
    final taken = List<bool>.filled(text.length, false);
    final hits = <({int start, int end, EntityType type})>[];
    // A regex scan of one term resumes after each match it finds, so it
    // never sees that term's own overlapping occurrences. Track the same
    // resume point per term so the result is identical.
    var scanRank = -1;
    var scanEnd = 0;
    for (final (rank, start, end) in found) {
      if (rank != scanRank) {
        scanRank = rank;
        scanEnd = 0;
      }
      if (start < scanEnd) continue;
      scanEnd = end;
      var free = true;
      for (var i = start; i < end; i++) {
        if (taken[i]) {
          free = false;
          break;
        }
      }
      if (!free) continue;
      for (var i = start; i < end; i++) {
        taken[i] = true;
      }
      hits.add((start: start, end: end, type: sorted[rank].type));
    }
    return _toRuns(text, hits);
  }
}

List<TextRun> _toRuns(
  String text,
  List<({int start, int end, EntityType type})> hits,
) {
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

// The general path, for text the fast path can't match exactly.
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

/// [sorted] must already be longest first.
List<TextRun> _highlightRunsRegex(String text, List<HighlightTerm> sorted) {
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
  return _toRuns(text, hits);
}
