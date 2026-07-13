// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'follow_up.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

FollowUp _$FollowUpFromJson(Map<String, dynamic> json) => FollowUp(
      id: json['id'] as String,
      question: json['question'] as String,
      reason: json['reason'] as String,
      targetEntityIds: (json['target_entity_ids'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      createdAt: DateTime.parse(json['created_at'] as String),
      answered: json['answered'] as bool,
    );

Map<String, dynamic> _$FollowUpToJson(FollowUp instance) => <String, dynamic>{
      'id': instance.id,
      'question': instance.question,
      'reason': instance.reason,
      'target_entity_ids': instance.targetEntityIds,
      'created_at': instance.createdAt.toIso8601String(),
      'answered': instance.answered,
    };
