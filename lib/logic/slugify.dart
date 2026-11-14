// Letters and digits of other scripts stay, so प्रिया, Иван and 李雷 get a stable
// id. Latin letters outside a-z, and combining marks, are separators as they
// always were: ids of existing Latin names don't change.
//
// Close to slugify() in src/lib/journal-store.ts and _slugify in the database,
// but not the same: those decompose first, which Dart can't. So й, Greek
// accents, Hangul, voiced kana and ễ give different ids here, and the web
// differs from the database on voiced kana. Two clients can give one person
// two ids; forget_entity and the commit also compare the name's database slug.
final _slugSeparators = RegExp(
  r'(?:(?![a-z0-9])(?:[^\p{L}\p{M}\p{N}]|\p{Script=Latin}|\p{Script=Inherited}))+',
  unicode: true,
);

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
  s = s.replaceAll(_slugSeparators, '-');
  s = s.replaceAll(RegExp(r'^-|-$'), '');
  final runes = s.runes;
  if (runes.length > 60) s = String.fromCharCodes(runes.take(60));
  if (s.isEmpty) return 'e-${DateTime.now().millisecondsSinceEpoch}';
  return s;
}

String relationId(String source, String label, String target) =>
    '${slugify(source)}__${label}__${slugify(target)}';
