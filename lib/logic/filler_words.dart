/// Hesitation sounds Gemini's transcription keeps ("um", "uh", "hmm").
///
/// Only sounds that never carry meaning are removed. Real words that are
/// sometimes used as filler ("like", "well", "you know") and affirmative
/// sounds ("uh-huh", "mm-hmm") stay, because removing them can change what
/// the user said.
final _filler = RegExp(
  r"(,\s*)?(?<![\w'-])(u+m+|u+h+m*|e+r+m*|h+m+|m{2,})(?![\w'-])"
  r'(\s*(?:,|…|\.{2,}))?\s*',
  caseSensitive: false,
);

final _sentenceEnd = RegExp(r'(^|[.?!])\s*$');
final _spaceBeforePunct = RegExp(r'\s+([,.?!;:])');
final _spaces = RegExp(r'\s{2,}');
final _onlyPunct = RegExp(r'^[\s,.…?!;:-]*$');

/// [text] without hesitation sounds and the commas or ellipses around them.
/// A sentence that started with one starts with a capital again. A turn of
/// nothing but hesitation becomes empty.
String stripFillers(String text) {
  final matches = _filler.allMatches(text).toList();
  if (matches.isEmpty) return text;

  final out = StringBuffer();
  var last = 0;
  var capitalizeNext = false;
  void keep(String segment) {
    if (capitalizeNext) {
      final i = segment.indexOf(RegExp(r'[A-Za-z]'));
      if (i >= 0) {
        segment = segment.substring(0, i) +
            segment[i].toUpperCase() +
            segment.substring(i + 1);
        capitalizeNext = false;
      }
    }
    out.write(segment);
  }

  for (final match in matches) {
    keep(text.substring(last, match.start));
    if (_sentenceEnd.hasMatch(out.toString())) capitalizeNext = true;
    out.write(' ');
    last = match.end;
  }
  keep(text.substring(last));

  final cleaned = out
      .toString()
      .replaceAllMapped(_spaceBeforePunct, (m) => m[1]!)
      .replaceAll(_spaces, ' ')
      .trim();
  return _onlyPunct.hasMatch(cleaned) ? '' : cleaned;
}
