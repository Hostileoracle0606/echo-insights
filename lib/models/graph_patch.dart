import 'entity.dart';

class EntityPatch {
  final String name;
  final EntityType type;
  final String? description;
  final Map<String, String>? metadata;
  final List<String>? questions;

  const EntityPatch({
    required this.name,
    required this.type,
    this.description,
    this.metadata,
    this.questions,
  });

  factory EntityPatch.fromJson(Map<String, dynamic> json) => EntityPatch(
        name: json['name'] as String,
        type: EntityType.values.firstWhere(
          (e) => e.name == json['type'],
          orElse: () => EntityType.other,
        ),
        description: json['description'] as String?,
        metadata: (json['metadata'] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(key, value.toString()),
        ),
        questions: (json['questions'] as List<dynamic>?)?.cast<String>(),
      );
}

class RelationPatch {
  final String source;
  final String target;
  final String label;
  final Map<String, String>? metadata;

  const RelationPatch({
    required this.source,
    required this.target,
    required this.label,
    this.metadata,
  });

  factory RelationPatch.fromJson(Map<String, dynamic> json) => RelationPatch(
        source: json['source'] as String,
        target: json['target'] as String,
        label: json['label'] as String,
        metadata: (json['metadata'] as Map<String, dynamic>?)?.map(
          (key, value) => MapEntry(key, value.toString()),
        ),
      );
}

class GraphPatch {
  final List<EntityPatch> entities;
  final List<RelationPatch> relations;
  final List<String> supersedes;

  const GraphPatch({
    required this.entities,
    required this.relations,
    required this.supersedes,
  });

  static GraphPatch empty() =>
      const GraphPatch(entities: [], relations: [], supersedes: []);

  factory GraphPatch.fromJson(Map<String, dynamic> json) => GraphPatch(
        entities: (json['entities'] as List<dynamic>? ?? [])
            .map((e) => EntityPatch.fromJson(e as Map<String, dynamic>))
            .toList(),
        relations: (json['relations'] as List<dynamic>? ?? [])
            .map((r) => RelationPatch.fromJson(r as Map<String, dynamic>))
            .toList(),
        supersedes: (json['supersedes'] as List<dynamic>? ?? []).cast<String>(),
      );
}
