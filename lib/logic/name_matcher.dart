/// Finding which of many names occur in a piece of text, in one pass.
///
/// Checking every name with `text.contains(name)` costs O(V · T) for V names
/// and text of length T. A trie of the names walked from each position of the
/// text costs O(T · L), where L is the longest name: independent of how many
/// names there are. Matching is on UTF-16 code units, exactly like
/// [String.contains], so callers keep their own normalisation.
library;

class _Node {
  final Map<int, _Node> next = {};

  /// Indexes of every key that ends here, in insertion order.
  List<int>? ends;
}

class NameTrie {
  NameTrie(Iterable<String> keys) {
    var index = 0;
    for (final key in keys) {
      var node = _root;
      for (final unit in key.codeUnits) {
        node = node.next.putIfAbsent(unit, _Node.new);
      }
      (node.ends ??= []).add(index);
      index++;
    }
  }

  final _Node _root = _Node();

  /// Indexes of the keys that occur anywhere in [text], as [String.contains]
  /// would report them. An empty key occurs in every text.
  Set<int> containedIn(String text) {
    final found = <int>{...?_root.ends};
    final units = text.codeUnits;
    for (var start = 0; start < units.length; start++) {
      var node = _root;
      for (var i = start; i < units.length; i++) {
        final step = node.next[units[i]];
        if (step == null) break;
        node = step;
        final ends = node.ends;
        if (ends != null) found.addAll(ends);
      }
    }
    return found;
  }

  /// Calls [onMatch] for every non-empty key that starts at [start] in
  /// [units], with the first key index that ends there and the end offset.
  void matchesFrom(
    List<int> units,
    int start,
    void Function(int key, int end) onMatch,
  ) {
    var node = _root;
    for (var i = start; i < units.length; i++) {
      final step = node.next[units[i]];
      if (step == null) return;
      node = step;
      final ends = node.ends;
      if (ends != null) onMatch(ends.first, i + 1);
    }
  }
}
