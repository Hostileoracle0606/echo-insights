/// What Lumen has already brought up this session, for the graph summary's
/// `probedThisSession` ("DO NOT re-ask about these").
///
/// A topic counts once Lumen has said its name: a person or thing from this
/// notebook's graph ([known]), or one that get_relevant_memory surfaced from
/// another conversation ([recalledIds], entity ids such as "priya-raman").
/// Names match as whole words, ignoring case. Graph names come first, in the
/// order given, then recalled ones.
List<String> probedThisSession({
  required Iterable<String> lumenSaid,
  required Iterable<String> known,
  Iterable<String> recalledIds = const [],
}) {
  final said = lumenSaid.join('\n').toLowerCase();
  if (said.isEmpty) return const [];

  final seen = <String>{};
  final probed = <String>[];
  final candidates = [
    ...known,
    for (final id in recalledIds) id.replaceAll(RegExp(r'[-_]+'), ' ').trim(),
  ];
  for (final name in candidates) {
    final key = name.toLowerCase();
    if (key.length < 2 || !seen.add(key)) continue;
    final pattern = RegExp('(?<![a-z0-9])${RegExp.escape(key)}(?![a-z0-9])');
    if (pattern.hasMatch(said)) probed.add(name);
  }
  return probed;
}

/// The latest [max] of [lines], oldest first: what Lumen said most recently
/// is what it must not repeat.
List<String> recentLines(Iterable<String> lines, {int max = 8}) {
  final all = lines.toList(growable: false);
  return all.length <= max ? all : all.sublist(all.length - max);
}
