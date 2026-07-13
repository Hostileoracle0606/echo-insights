import '../models/agenda.dart';
import '../models/journal_state.dart';

int _wordCount(String? s) =>
    s == null || s.isEmpty ? 0 : s.trim().split(RegExp(r'\s+')).length;

Agenda buildAgenda(JournalState state, {String? lastUserText}) {
  final entities = state.entities.values.toList();
  final activeRelations =
      state.relations.values.where((relation) => relation.isActive).toList();

  final wordsByEntity = <String, int>{};
  for (final entity in entities) {
    wordsByEntity[entity.id] = _wordCount(entity.description);
  }
  for (final entry in state.entries) {
    for (final entityId in entry.entityIds) {
      wordsByEntity[entityId] =
          (wordsByEntity[entityId] ?? 0) + _wordCount(entry.text);
    }
  }

  final thinEntities = entities
      .where((entity) => (wordsByEntity[entity.id] ?? 0) < 30)
      .toList()
    ..sort((a, b) => b.mentions.compareTo(a.mentions));

  final probeText =
      (lastUserText ?? (state.entries.isEmpty ? '' : state.entries.first.text))
          .toLowerCase();
  final justMentioned = entities
      .where((entity) => probeText.contains(entity.name.toLowerCase()))
      .map((entity) => entity.name)
      .toList();

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

  final activePairCount = <String, int>{};
  for (final relation in activeRelations) {
    final key = '${relation.source} ${relation.target}';
    activePairCount[key] = (activePairCount[key] ?? 0) + 1;
  }

  final uncertainRelations = activeRelations
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
        if ((activePairCount['${relation.source} ${relation.target}'] ?? 0) <=
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
      .where((relation) => relation.score >= 2)
      .toList()
    ..sort((a, b) => b.score.compareTo(a.score));

  final neighbors = <String, Set<String>>{};
  final directlyLinked = <String>{};
  for (final relation in activeRelations) {
    neighbors.putIfAbsent(relation.source, () => {}).add(relation.target);
    neighbors.putIfAbsent(relation.target, () => {}).add(relation.source);
    final key = [relation.source, relation.target]..sort();
    directlyLinked.add(key.join(' '));
  }

  final ids = neighbors.keys.toList();
  final bridges = <({String a, String b, int shared})>[];
  for (var i = 0; i < ids.length; i++) {
    for (var j = i + 1; j < ids.length; j++) {
      final a = ids[i];
      final b = ids[j];
      final key = ([a, b]..sort()).join(' ');
      if (directlyLinked.contains(key)) continue;
      final shared = neighbors[a]!.intersection(neighbors[b]!).length;
      if (shared > 0) bridges.add((a: a, b: b, shared: shared));
    }
  }
  bridges.sort((x, y) => y.shared.compareTo(x.shared));
  final bridgeCandidates = bridges
      .take(6)
      .map(
        (bridge) => (
          state.entities[bridge.a]?.name ?? bridge.a,
          state.entities[bridge.b]?.name ?? bridge.b,
        ),
      )
      .toList();

  final openQuestions = entities
      .expand(
        (entity) => (entity.questions ?? []).map(
          (question) => OpenQuestion(entity: entity.name, question: question),
        ),
      )
      .take(12)
      .toList();

  return Agenda(
    thinEntities: thinEntities.take(10).map((entity) => entity.name).toList(),
    justMentioned: justMentioned,
    uncertainRelations: uncertainRelations.take(3).toList(),
    bridgeCandidates: bridgeCandidates,
    openQuestions: openQuestions,
    entityCount: entities.length,
    relationCount: activeRelations.length,
  );
}
