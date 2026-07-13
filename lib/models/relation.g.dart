// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'relation.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Relation _$RelationFromJson(Map<String, dynamic> json) => Relation(
      id: json['id'] as String,
      source: json['source'] as String,
      target: json['target'] as String,
      label: json['label'] as String,
      metadata: json['metadata'] as Map<String, dynamic>,
      createdAt: DateTime.parse(json['created_at'] as String),
      supersededAt: json['superseded_at'] == null
          ? null
          : DateTime.parse(json['superseded_at'] as String),
    );

Map<String, dynamic> _$RelationToJson(Relation instance) => <String, dynamic>{
      'id': instance.id,
      'source': instance.source,
      'target': instance.target,
      'label': instance.label,
      'metadata': instance.metadata,
      'created_at': instance.createdAt.toIso8601String(),
      'superseded_at': instance.supersededAt?.toIso8601String(),
    };
