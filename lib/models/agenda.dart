class UncertainRelation {
  final String source;
  final String label;
  final String target;
  final int score;

  const UncertainRelation({
    required this.source,
    required this.label,
    required this.target,
    required this.score,
  });
}

class OpenQuestion {
  final String entity;
  final String question;

  const OpenQuestion({required this.entity, required this.question});
}

class Agenda {
  final List<String> thinEntities;
  final List<String> justMentioned;
  final List<UncertainRelation> uncertainRelations;
  final List<(String, String)> bridgeCandidates;
  final List<OpenQuestion> openQuestions;
  final int entityCount;
  final int relationCount;

  const Agenda({
    required this.thinEntities,
    required this.justMentioned,
    required this.uncertainRelations,
    required this.bridgeCandidates,
    required this.openQuestions,
    required this.entityCount,
    required this.relationCount,
  });
}
