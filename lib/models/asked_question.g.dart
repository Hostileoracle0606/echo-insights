// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'asked_question.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

AskedQuestion _$AskedQuestionFromJson(Map<String, dynamic> json) =>
    AskedQuestion(
      id: json['id'] as String,
      question: json['question'] as String,
      targetEntityIds: (json['target_entity_ids'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      askedAt: DateTime.parse(json['asked_at'] as String),
    );

Map<String, dynamic> _$AskedQuestionToJson(AskedQuestion instance) =>
    <String, dynamic>{
      'id': instance.id,
      'question': instance.question,
      'target_entity_ids': instance.targetEntityIds,
      'asked_at': instance.askedAt.toIso8601String(),
    };
