// Names that are also words: does this use look like a name? (LM-55)
//
// Only asked of a capitalised match for an entity the graph knows whose name
// is an ordinary word (Will, June, Rose, May, Mark). A lowercase use is never
// a name. Ported from the spike's rules and generalised; the rules are
// cheap heuristics, and a wrong "not a name" leaves the name unswapped (it
// leaks), a wrong "name" swaps an ordinary word (harmless, restored on the
// way back).

final _beforeMonth = RegExp(
  r'\b(in|of|last|next|early|late|mid|since|until|by|this|every|during|from|to|on|before|after)\s+$',
  caseSensitive: false,
);
final _sentenceStart = RegExp(r'(^|[.!?:\n]["”’\)]?\s+)$');
final _auxNext = RegExp(
  r"^\s*(you|we|i|they|it|he|she|that|this|there|the|be|have|not|probably|definitely|just|also|still|never|always|someone|everyone|anyone|do|go|get|help|see|work|need|miss|the|your|my|a|an|each|all|down|up|out|sure)\b",
  caseSensitive: false,
);
final _pronounBefore = RegExp(
  r'\b(i|you|we|they|it|he|she|that|who|which|there|this|to|can|could|would|should|might|must)\s+$',
  caseSensitive: false,
);
final _determinerBefore = RegExp(
  r'\b(the|a|an|my|your|his|her|our|their|of|no|any|some|this|that|what|every|each|one|per|to)\s+$',
  caseSensitive: false,
);
final _roseVerbBefore = RegExp(
  r'\b(price|prices|sun|moon|heat|temperature|tide|he|she|it|they|who|smoke|dough|then|that)\s+$',
  caseSensitive: false,
);
final _roseVerbAfter =
    RegExp(r'^\s+(to|from|by|above|slowly|quickly|again|up|early|and then)\b', caseSensitive: false);
final _nameAfter = RegExp(
  r"""^(['’]s\b|,|\s+(said|says|called|calls|texted|texts|told|tells|asked|asks|is|was|has|had|wants|wanted|thinks|thought|laughed|came|went|and|who|from|at|in|lives|works|just|really|also|always|never|did|does|got|gets|knew|knows|likes|liked|loves|loved|hates|hated|moved|met|saw|sees|wrote|writes|replied|replies)\b)""",
  caseSensitive: false,
);

/// True when the word-name [name] at [start, end) of [text] reads as a name.
bool wordNameLooksLikeName(String name, String text, int start, int end) {
  final from = start > 24 ? start - 24 : 0;
  final to = end + 24 < text.length ? end + 24 : text.length;
  final before = text.substring(from, start);
  final after = text.substring(end, to);
  final atSentenceStart = start == 0 || _sentenceStart.hasMatch(before);
  switch (name.toLowerCase()) {
    case 'june':
    case 'may':
    case 'march':
    case 'april':
    case 'august':
      if (_beforeMonth.hasMatch(before)) return false;
      if (RegExp(r'^\s+\d').hasMatch(after)) return false;
      if (name.toLowerCase() == 'may' &&
          atSentenceStart &&
          RegExp(r'^\s+(i|we|you|he|she|they|it|be|not)\b', caseSensitive: false)
              .hasMatch(after)) {
        return false;
      }
      return true;
    case 'will':
      if (atSentenceStart && _auxNext.hasMatch(after)) return false;
      if (!atSentenceStart && _pronounBefore.hasMatch(before)) return false;
      return true;
    case 'rose':
      if (_roseVerbAfter.hasMatch(after)) return false;
      if (_roseVerbBefore.hasMatch(before)) return false;
      return true;
    case 'mark':
      if (!atSentenceStart && (_determinerBefore.hasMatch(before) || _pronounBefore.hasMatch(before))) {
        return false;
      }
      if (atSentenceStart && _auxNext.hasMatch(after)) return false;
      return true;
    default:
      // Other word-names (Hope, Grace, Bill, Pat): mid-sentence, not after a
      // determiner. At a sentence start only when a name-like word follows.
      if (atSentenceStart) return _nameAfter.hasMatch(after);
      return !_determinerBefore.hasMatch(before);
  }
}
