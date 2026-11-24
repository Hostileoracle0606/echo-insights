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

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type.name,
        if (description != null) 'description': description,
        if (metadata != null) 'metadata': metadata,
        if (questions != null) 'questions': questions,
      };
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

  Map<String, dynamic> toJson() => {
        'source': source,
        'target': target,
        'label': label,
        if (metadata != null) 'metadata': metadata,
      };
}

/// EC-03: a typed value the user stated ("savings goal amount = 8000 USD").
/// Recorded after the turn commits; the database decides whether it repeats,
/// supersedes or is overruled by a correction.
class FactPatch {
  final String entity;
  final String attribute;
  final num? valueNum;
  final String? valueText;
  final String? unit;
  final String status;
  final String? eventAt;
  final num? previousValueNum;
  final String? previousValueText;

  const FactPatch({
    required this.entity,
    required this.attribute,
    this.valueNum,
    this.valueText,
    this.unit,
    required this.status,
    this.eventAt,
    this.previousValueNum,
    this.previousValueText,
  });

  /// Null when [json] is not a usable fact: a checkpoint never fails on one.
  static FactPatch? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final entity = json['entity'];
    final attribute = json['attribute'];
    final status = json['status'];
    final valueNum = json['valueNum'];
    final valueText = json['valueText'];
    if (entity is! String || entity.isEmpty) return null;
    if (attribute is! String || attribute.isEmpty) return null;
    if (status is! String ||
        !const ['confirmed', 'proposed', 'cancelled'].contains(status)) {
      return null;
    }
    if (valueNum != null && valueNum is! num) return null;
    if (valueText != null && valueText is! String) return null;
    if (valueNum == null && (valueText == null || (valueText as String).isEmpty)) {
      return null;
    }
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    return FactPatch(
      entity: entity,
      attribute: attribute,
      valueNum: valueNum as num?,
      valueText: text(valueText),
      unit: text(json['unit']),
      status: status,
      eventAt: text(json['eventAt']),
      previousValueNum: json['previousValueNum'] is num ? json['previousValueNum'] as num : null,
      previousValueText: text(json['previousValueText']),
    );
  }

  Map<String, dynamic> toJson() => {
        'entity': entity,
        'attribute': attribute,
        if (valueNum != null) 'valueNum': valueNum,
        if (valueText != null) 'valueText': valueText,
        if (unit != null) 'unit': unit,
        'status': status,
        if (eventAt != null) 'eventAt': eventAt,
        if (previousValueNum != null) 'previousValueNum': previousValueNum,
        if (previousValueText != null) 'previousValueText': previousValueText,
      };
}

class GraphPatch {
  final List<EntityPatch> entities;
  final List<RelationPatch> relations;
  final List<String> supersedes;
  final List<FactPatch> facts;

  const GraphPatch({
    required this.entities,
    required this.relations,
    required this.supersedes,
    this.facts = const [],
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
        facts: [
          for (final raw in json['facts'] as List<dynamic>? ?? const [])
            if (FactPatch.tryFromJson(raw) case final fact?) fact,
        ],
      );

  /// Round-trips through [GraphPatch.fromJson] without loss. This is what lets
  /// a finalized turn checkpoint its extraction result durably, so a restart
  /// after extraction reuses the exact result the model returned instead of
  /// paying for the call again and possibly receiving a different answer.
  Map<String, dynamic> toJson() => {
        'entities': entities.map((e) => e.toJson()).toList(),
        'relations': relations.map((r) => r.toJson()).toList(),
        'supersedes': supersedes,
        if (facts.isNotEmpty) 'facts': facts.map((f) => f.toJson()).toList(),
      };
}
