import '../models/journal_state.dart';
import 'agenda.dart';

/// The part of the `get_graph_summary` tool answer that depends only on the
/// notebook and the user's latest words. JournalNotifier adds the fields
/// that depend on the conversation and the clock.
///
/// Relation counts come from one pass over the relations (O(V + R)), not one
/// scan of every relation per entity (O(V · R)).
Map<String, dynamic> graphSummaryBody(
  JournalState state, {
  required String lastUserText,
}) {
  final agenda = buildAgenda(state, lastUserText: lastUserText);
  final degree = <String, int>{};
  for (final relation in state.relations.values) {
    if (!relation.isActive) continue;
    degree[relation.source] = (degree[relation.source] ?? 0) + 1;
    if (relation.target != relation.source) {
      degree[relation.target] = (degree[relation.target] ?? 0) + 1;
    }
  }
  final thin = agenda.thinEntities.toSet();
  return {
    'mode': 'granular',
    'entityCount': agenda.entityCount,
    'relationCount': agenda.relationCount,
    'entities': state.entities.values
        .map(
          (entity) => {
            'name': entity.name,
            'type': entity.type.name,
            'coverage': thin.contains(entity.name) ? 'thin' : 'developing',
            'mentions': entity.mentions,
            'relationCount': degree[entity.id] ?? 0,
            'openQuestions': entity.questions ?? const <String>[],
          },
        )
        .toList(),
    'thinEntities': agenda.thinEntities.take(5).toList(),
    'justMentioned': agenda.justMentioned,
    'uncertainRelations': agenda.uncertainRelations
        .map(
          (relation) => {
            'source': relation.source,
            'label': relation.label,
            'target': relation.target,
            'score': relation.score,
          },
        )
        .toList(),
    'bridgeCandidates':
        agenda.bridgeCandidates.map((pair) => [pair.$1, pair.$2]).toList(),
    'openQuestionsTop': agenda.openQuestions
        .take(5)
        .map(
          (question) => {
            'entity': question.entity,
            'question': question.question,
          },
        )
        .toList(),
  };
}
