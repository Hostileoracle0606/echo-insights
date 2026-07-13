String snippet(String text, {int max = 140}) {
  final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.length <= max) return clean;

  final cut = clean.substring(0, max);
  final lastSpace = cut.lastIndexOf(' ');
  final base = lastSpace > 0 ? cut.substring(0, lastSpace) : cut;

  return '${base.trimRight()}…';
}
