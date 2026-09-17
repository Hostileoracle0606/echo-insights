import '../logic/noise_filter.dart';
import '../models/entity.dart';
import '../models/follow_up.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';

typedef ConversationTurn = ({String role, String text});

const defaultExtractionTokenBudget = 1800;
const _maxEntities = 20;
const _maxRelations = 30;
const _maxTurns = 4;

class ExtractionContext {
  final List<Entity> entities;
  final List<Relation> relations;
  final List<ConversationTurn> recentConversation;
  final FollowUp? answeringFollowUp;
  final int tokensUsed;
  final int budget;

  const ExtractionContext({
    required this.entities,
    required this.relations,
    required this.recentConversation,
    required this.answeringFollowUp,
    required this.tokensUsed,
    required this.budget,
  });
}

int estimateExtractionTokens(String text) {
  if (text.isEmpty) return 0;
  var tokens = 0;
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final estimated = (word.length / 4).ceil();
    tokens += estimated < 1 ? 1 : estimated;
  }
  return tokens;
}

String buildExtractionUserMessage(
  String text,
  ExtractionContext context,
) {
  final namesById = {
    for (final entity in context.entities) entity.id: entity.name,
  };
  final existingList = context.entities.isEmpty
      ? '(none yet)'
      : context.entities
          .map(
            (entity) =>
                '- ${entity.name} (${entity.type.name})${entity.description != null ? " - ${entity.description}" : ""}',
          )
          .join('\n');
  final relationList = context.relations.isEmpty
      ? '(none yet)'
      : context.relations
          .map(
            (relation) =>
                '- [${relation.id}] ${namesById[relation.source] ?? relation.source} --${relation.label}--> ${namesById[relation.target] ?? relation.target}',
          )
          .join('\n');
  final recentList = context.recentConversation.isEmpty
      ? '(none)'
      : context.recentConversation
          .map((turn) => '- ${turn.role}: ${turn.text}')
          .join('\n');
  final followUp = context.answeringFollowUp;
  final followUpSection = followUp == null
      ? ''
      : '''

QUESTION BEING ANSWERED (grounding only):
- ${followUp.question}${followUp.reason.isEmpty ? '' : ' — ${followUp.reason}'}''';

  return '''EXISTING ENTITIES (reuse these spellings for the same thing):
$existingList

EXISTING RELATIONS (each prefixed with its [id] — use these IDs verbatim in supersedes when contradicted):
$relationList

RECENT CONVERSATION (for pronoun resolution only — do NOT extract from these):
$recentList$followUpSection

NEW UTTERANCE:
"""$text"""''';
}

ExtractionContext compileExtractionContext({
  required String transcript,
  required JournalState state,
  required List<String> retrievedEntityIds,
  required List<ConversationTurn> recentTurns,
  FollowUp? answeringFollowUp,
  int budget = defaultExtractionTokenBudget,
  int Function(String text) countTokens = estimateExtractionTokens,
}) {
  final normalizedTranscript = normalizeName(transcript);
  final exactIds = <String>[];
  for (final entity in state.entities.values) {
    final normalized = normalizeName(entity.name);
    if (normalized.length >= 2 && normalizedTranscript.contains(normalized)) {
      exactIds.add(entity.id);
    }
  }

  final candidateIds = <String>[
    ...exactIds,
    ...retrievedEntityIds.where((id) => !exactIds.contains(id)),
  ];
  final entities = <Entity>[];
  final relations = <Relation>[];
  final turns = <ConversationTurn>[];
  FollowUp? includedFollowUp;

  ExtractionContext snapshot() {
    final partial = ExtractionContext(
      entities: List.unmodifiable(entities),
      relations: List.unmodifiable(relations),
      recentConversation: List.unmodifiable(turns),
      answeringFollowUp: includedFollowUp,
      tokensUsed: 0,
      budget: budget,
    );
    return ExtractionContext(
      entities: partial.entities,
      relations: partial.relations,
      recentConversation: partial.recentConversation,
      answeringFollowUp: partial.answeringFollowUp,
      tokensUsed: countTokens(buildExtractionUserMessage(transcript, partial)),
      budget: budget,
    );
  }

  bool fits() => snapshot().tokensUsed <= budget;

  // The finalized utterance is never truncated. If it consumes the budget on
  // its own, no grounding material is added.
  if (fits()) {
    for (final id in candidateIds) {
      if (entities.length >= _maxEntities) break;
      final entity = state.entities[id];
      if (entity == null || entities.any((item) => item.id == id)) continue;
      entities.add(entity);
      if (!fits()) {
        entities.removeLast();
        break;
      }
    }

    final keptIds = entities.map((entity) => entity.id).toSet();
    final candidates = state.relations.values
        .where(
          (relation) =>
              relation.isActive &&
              keptIds.contains(relation.source) &&
              keptIds.contains(relation.target),
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    for (final relation in candidates) {
      if (relations.length >= _maxRelations) break;
      relations.add(relation);
      if (!fits()) {
        relations.removeLast();
        break;
      }
    }

    if (answeringFollowUp != null) {
      includedFollowUp = answeringFollowUp;
      if (!fits()) includedFollowUp = null;
    }

    // Iterate newest-first, prepend each accepted turn, and therefore keep the
    // selected tail in chronological order for pronoun resolution.
    for (final turn in recentTurns.reversed) {
      if (turns.length >= _maxTurns) break;
      turns.insert(0, turn);
      if (!fits()) {
        turns.removeAt(0);
        break;
      }
    }
  }

  return snapshot();
}
