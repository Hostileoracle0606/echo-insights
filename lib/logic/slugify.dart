String slugify(String name) {
  var s = name.toLowerCase();
  s = s
      .replaceAll(RegExp(r'[àáâãäå]'), 'a')
      .replaceAll(RegExp(r'[èéêë]'), 'e')
      .replaceAll(RegExp(r'[ìíîï]'), 'i')
      .replaceAll(RegExp(r'[òóôõö]'), 'o')
      .replaceAll(RegExp(r'[ùúûü]'), 'u')
      .replaceAll(RegExp(r'[ñ]'), 'n')
      .replaceAll(RegExp(r'[ç]'), 'c');
  s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  s = s.replaceAll(RegExp(r'^-|-$'), '');
  if (s.length > 60) s = s.substring(0, 60);
  if (s.isEmpty) return 'e-${DateTime.now().millisecondsSinceEpoch}';
  return s;
}

String relationId(String source, String label, String target) =>
    '${slugify(source)}__${label}__${slugify(target)}';
