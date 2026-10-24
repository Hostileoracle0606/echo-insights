// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'entity.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Entity _$EntityFromJson(Map<String, dynamic> json) => Entity(
      id: json['id'] as String,
      name: json['name'] as String,
      type: $enumDecode(_$EntityTypeEnumMap, json['type']),
      description: json['description'] as String?,
      descriptionSource: json['descriptionSource'] as String? ?? 'extracted',
      metadata: json['metadata'] as Map<String, dynamic>,
      mentions: (json['mentions'] as num).toInt(),
      firstSeen: DateTime.parse(json['firstSeen'] as String),
      lastSeen: DateTime.parse(json['lastSeen'] as String),
      questions: (json['questions'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$EntityToJson(Entity instance) => <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'type': _$EntityTypeEnumMap[instance.type]!,
      'description': instance.description,
      'descriptionSource': instance.descriptionSource,
      'metadata': instance.metadata,
      'mentions': instance.mentions,
      'firstSeen': instance.firstSeen.toIso8601String(),
      'lastSeen': instance.lastSeen.toIso8601String(),
      'questions': instance.questions,
    };

const _$EntityTypeEnumMap = {
  EntityType.person: 'person',
  EntityType.place: 'place',
  EntityType.organization: 'organization',
  EntityType.project: 'project',
  EntityType.event: 'event',
  EntityType.activity: 'activity',
  EntityType.concept: 'concept',
  EntityType.emotion: 'emotion',
  EntityType.other: 'other',
};
