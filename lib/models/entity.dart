import 'package:json_annotation/json_annotation.dart';

part 'entity.g.dart';

enum EntityType {
  person,
  place,
  organization,
  project,
  event,
  activity,
  concept,
  emotion,
  other,
}

@JsonSerializable()
class Entity {
  final String id;
  final String name;
  final EntityType type;
  final String? description;

  /// Who wrote [description]: `'extracted'` (Lumen) or `'user'`. A
  /// user-written description is never replaced by extraction (LM-29).
  @JsonKey(defaultValue: 'extracted')
  final String descriptionSource;
  final Map<String, dynamic> metadata;
  final int mentions;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final List<String>? questions;

  const Entity({
    required this.id,
    required this.name,
    required this.type,
    this.description,
    this.descriptionSource = 'extracted',
    required this.metadata,
    required this.mentions,
    required this.firstSeen,
    required this.lastSeen,
    this.questions,
  });

  factory Entity.fromJson(Map<String, dynamic> json) => _$EntityFromJson(json);
  Map<String, dynamic> toJson() => _$EntityToJson(this);

  Entity copyWith({
    String? description,
    String? descriptionSource,
    Map<String, dynamic>? metadata,
    int? mentions,
    DateTime? lastSeen,
    EntityType? type,
    List<String>? questions,
  }) =>
      Entity(
        id: id,
        name: name,
        type: type ?? this.type,
        description: description ?? this.description,
        descriptionSource: descriptionSource ?? this.descriptionSource,
        metadata: metadata ?? this.metadata,
        mentions: mentions ?? this.mentions,
        firstSeen: firstSeen,
        lastSeen: lastSeen ?? this.lastSeen,
        questions: questions ?? this.questions,
      );
}
