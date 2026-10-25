import '../models/agenda.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';
import 'name_matcher.dart';

int _wordCount(String? s) =>
    s == null || s.isEmpty ? 0 : s.trim().split(RegExp(r'\s+')).length;

/// The first [k] items of [items] ordered by [compare], keeping the original
/// order among ties (a stable top-k). O(n · k) with k small, instead of
/// sorting everything to take a few.
List<T> _topK<T>(Iterable<T> items, int k, int Function(T a, T b) compare) {
  final best = <T>[];
  for (final item in items) {
    if (best.length == k && compare(item, best.last) >= 0) continue;
    var at = best.length;
    while (at > 0 && compare(item, best[at - 1]) < 0) {
      at--;
    }
    best.insert(at, item);
    if (best.length > k) best.removeLast();
  }
  return best;
}

Agenda buildAgenda(JournalState state, {String? lastUserText}) {
  final entities = state.entities.values.toList();
  final activeRelations =
      state.relations.values.where((relation) => relation.isActive).toList();

  // Each entry's words are counted once, then credited to its entities.
  final wordsByEntity = <String, int>{};
  for (final entity in entities) {
    wordsByEntity[entity.id] = _wordCount(entity.description);
  }
  for (final entry in state.entries) {
    if (entry.entityIds.isEmpty) continue;
    final words = _wordCount(entry.text);
    for (final entityId in entry.entityIds) {
      wordsByEntity[entityId] = (wordsByEntity[entityId] ?? 0) + words;
    }
  }

  final thinEntities = _topK(
    entities.where((entity) => (wordsByEntity[entity.id] ?? 0) < 30),
    10,
    (a, b) => b.mentions.compareTo(a.mentions),
  );

  // Which entity names the user's latest words contain: one trie walk over
  // the text instead of one substring search per entity.
  final probeText =
      (lastUserText ?? (state.entries.isEmpty ? '' : state.entries.first.text))
          .toLowerCase();
  final contained =
      NameTrie(entities.map((entity) => entity.name.toLowerCase()))
          .containedIn(probeText);
  final justMentioned = [
    for (var i = 0; i < entities.length; i++)
      if (contained.contains(i)) entities[i].name,
  ];

  final mentionCountByRelation = <String, int>{};
  final firstEntryByEntity = <String, String>{};
  for (final entry in state.entries) {
    for (final relationId in entry.relationIds) {
      mentionCountByRelation[relationId] =
          (mentionCountByRelation[relationId] ?? 0) + 1;
    }
    for (final entityId in entry.entityIds) {
      firstEntryByEntity.putIfAbsent(entityId, () => entry.id);
    }
  }

  final activePairCount = <(String, String), int>{};
  for (final relation in activeRelations) {
    final key = (relation.source, relation.target);
    activePairCount[key] = (activePairCount[key] ?? 0) + 1;
  }

  final uncertainRelations = _topK(
    activeRelations
        .map((relation) {
          var score = 0;
          if ((mentionCountByRelation[relation.id] ?? 0) <= 1) score++;
          final sourceEntry = firstEntryByEntity[relation.source];
          final targetEntry = firstEntryByEntity[relation.target];
          if (sourceEntry != null &&
              targetEntry != null &&
              sourceEntry != targetEntry) {
            score++;
          }
          if ((activePairCount[(relation.source, relation.target)] ?? 0) <=
              1) {
            score++;
          }
          return UncertainRelation(
            source: state.entities[relation.source]?.name ?? relation.source,
            label: relation.label,
            target: state.entities[relation.target]?.name ?? relation.target,
            score: score,
          );
        })
        .where((relation) => relation.score >= 2),
    3,
    (a, b) => b.score.compareTo(a.score),
  );

  final bridgeCandidates = [
    for (final (a, b) in _bridges(activeRelations, 6))
      (state.entities[a]?.name ?? a, state.entities[b]?.name ?? b),
  ];

  final openQuestions = entities
      .expand(
        (entity) => (entity.questions ?? []).map(
          (question) => OpenQuestion(entity: entity.name, question: question),
        ),
      )
      .take(12)
      .toList();

  return Agenda(
    thinEntities: thinEntities.map((entity) => entity.name).toList(),
    justMentioned: justMentioned,
    uncertainRelations: uncertainRelations,
    bridgeCandidates: bridgeCandidates,
    openQuestions: openQuestions,
    entityCount: entities.length,
    relationCount: activeRelations.length,
  );
}

/// The [k] pairs of entities that are not linked but share the most
/// neighbours — natural "how did A end up at B?" questions.
///
/// A pair (a, b) shares neighbour m exactly when both are neighbours of m, so
/// counting every pair of each node's neighbours ("wedges") gives each pair's
/// shared count in O(sum of degree²), instead of intersecting the neighbour
/// sets of all O(V²) pairs. Ties go to the pair seen first (a's first
/// appearance, then b's), so the same graph always gives the same pairs.
List<(String, String)> _bridges(Iterable<Relation> activeRelations, int k) {
  final neighbors = <String, Set<String>>{};
  for (final relation in activeRelations) {
    neighbors.putIfAbsent(relation.source, () => {}).add(relation.target);
    neighbors.putIfAbsent(relation.target, () => {}).add(relation.source);
  }
  final ids = neighbors.keys.toList(growable: false);
  final index = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  final n = ids.length;
  final shared = <int, int>{}; // key = i * n + j, with i < j
  for (final around in neighbors.values) {
    final sorted = [for (final id in around) index[id]!]..sort();
    for (var p = 0; p < sorted.length; p++) {
      for (var q = p + 1; q < sorted.length; q++) {
        final key = sorted[p] * n + sorted[q];
        shared[key] = (shared[key] ?? 0) + 1;
      }
    }
  }
  final candidates = [
    for (final MapEntry(:key, :value) in shared.entries)
      if (!neighbors[ids[key ~/ n]]!.contains(ids[key % n])) (key, value),
  ];
  final best = _topK<(int, int)>(
    candidates,
    k,
    (x, y) => x.$2 != y.$2 ? y.$2.compareTo(x.$2) : x.$1.compareTo(y.$1),
  );
  return [for (final (key, _) in best) (ids[key ~/ n], ids[key % n])];
}
