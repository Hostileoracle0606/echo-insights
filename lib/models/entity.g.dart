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
      metadata: json['metadata'] as Map<String, dynamic>,
      mentions: (json['mentions'] as num).toInt(),
      firstSeen: DateTime.parse(json['first_seen'] as String),
      lastSeen: DateTime.parse(json['last_seen'] as String),
      questions: (json['questions'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
    );

Map<String, dynamic> _$EntityToJson(Entity instance) => <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'type': _$EntityTypeEnumMap[instance.type]!,
      'description': instance.description,
      'metadata': instance.metadata,
      'mentions': instance.mentions,
      'first_seen': instance.firstSeen.toIso8601String(),
      'last_seen': instance.lastSeen.toIso8601String(),
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
