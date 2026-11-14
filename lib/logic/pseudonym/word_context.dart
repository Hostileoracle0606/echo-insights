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
  r"^\s*(you|we|i|they|it|he|she|that|this|there|the|be|have|not|probably|definitely|just|also|still|never|always|someone|everyone|anyone|do|go|get|help|see|work|need|miss|your|my|a|an|each|all|down|up|out|sure)\b",
  caseSensitive: false,
);
// Only consulted for ALL CAPS text, where capitalisation says nothing.
final _subjectBefore = RegExp(
  r'\b(i|you|we|they|he|she|it|who|that|which|there|this|can|could|would|should|might|must)\s+$',
  caseSensitive: false,
);
final _determinerBefore = RegExp(
  r'\b(the|a|an|every|each|any|some|no)\s+$',
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

const _months = {'june', 'may', 'march', 'april', 'august'};

/// True when the word-name [name] at [start, end) of [text] reads as a name.
///
/// A capitalised word in the middle of a sentence is almost always a name:
/// "talked to Will", "is it Rose", "that Mark is here". Only two places make
/// the capital uninformative, a sentence start and ALL CAPS, and only there
/// do the verb/aux rules (Will you.., Rose to.., Mark the date) apply. Months
/// have their own rules.
bool wordNameLooksLikeName(String name, String text, int start, int end) {
  final from = start > 24 ? start - 24 : 0;
  final to = end + 24 < text.length ? end + 24 : text.length;
  final before = text.substring(from, start);
  final after = text.substring(end, to);
  final matched = text.substring(start, end);
  final allCaps = matched.length > 1 &&
      matched == matched.toUpperCase() &&
      matched != matched.toLowerCase();
  final atSentenceStart = start == 0 || _sentenceStart.hasMatch(before);
  final lower = name.toLowerCase();

  if (_months.contains(lower)) {
    if (_beforeMonth.hasMatch(before)) return false;
    if (RegExp(r'^\s+\d').hasMatch(after)) return false;
    if (lower == 'may' &&
        (atSentenceStart || allCaps) &&
        RegExp(r'^\s+(i|we|you|he|she|they|it|be|not)\b', caseSensitive: false)
            .hasMatch(after)) {
      return false;
    }
    return true;
  }

  final ambiguous = atSentenceStart || allCaps;
  switch (lower) {
    case 'will':
      if (atSentenceStart && _auxNext.hasMatch(after)) return false;
      if (allCaps && !atSentenceStart && _subjectBefore.hasMatch(before)) return false;
      return true;
    case 'rose':
      if (!ambiguous) return true;
      if (_roseVerbAfter.hasMatch(after)) return false;
      if (_roseVerbBefore.hasMatch(before)) return false;
      return true;
    case 'mark':
      if (!ambiguous) return true;
      if (atSentenceStart && _auxNext.hasMatch(after)) return false;
      if (!atSentenceStart &&
          (_determinerBefore.hasMatch(before) || _subjectBefore.hasMatch(before))) {
        return false;
      }
      return true;
    default:
      // Other word-names (Hope, Grace, Bill, Pat, a surname that is a word):
      // at a sentence start only when a name-like word follows; elsewhere
      // not right after "the", "a", "every"...
      if (atSentenceStart) return _nameAfter.hasMatch(after);
      return !_determinerBefore.hasMatch(before);
  }
}
