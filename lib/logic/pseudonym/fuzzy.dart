// Spelling and sound distance for the name swap (LM-55). Ported from the
// pseudonymization spike's swap.mjs; the thresholds that use them live in
// pseudonym_map.dart.

/// Edit distance between [a] and [b], ignoring case. Works on code points.
int editDistance(String a, String b) {
  final m = a.toLowerCase().runes.toList();
  final n = b.toLowerCase().runes.toList();
  var prev = List<int>.generate(n.length + 1, (i) => i);
  for (var i = 1; i <= m.length; i++) {
    final cur = <int>[i];
    for (var j = 1; j <= n.length; j++) {
      final sub = prev[j - 1] + (m[i - 1] == n[j - 1] ? 0 : 1);
      var best = sub;
      if (prev[j] + 1 < best) best = prev[j] + 1;
      if (cur[j - 1] + 1 < best) best = cur[j - 1] + 1;
      cur.add(best);
    }
    prev = cur;
  }
  return prev[n.length];
}

const _soundexCodes = <String, int>{
  'B': 1, 'F': 1, 'P': 1, 'V': 1, //
  'C': 2, 'G': 2, 'J': 2, 'K': 2, 'Q': 2, 'S': 2, 'X': 2, 'Z': 2,
  'D': 3, 'T': 3, 'L': 4, 'M': 5, 'N': 5, 'R': 6,
};

/// American Soundex of the Latin letters in [s] ('' when it has none).
String soundex(String s) {
  final t = s.toUpperCase().replaceAll(RegExp('[^A-Z]'), '');
  if (t.isEmpty) return '';
  final out = StringBuffer(t[0]);
  var last = _soundexCodes[t[0]] ?? 0;
  for (var i = 1; i < t.length; i++) {
    final ch = t[i];
    final c = _soundexCodes[ch] ?? 0;
    if (c != 0 && c != last) out.write(c);
    if (ch != 'H' && ch != 'W') last = c;
  }
  return '${out}000'.substring(0, 4);
}
