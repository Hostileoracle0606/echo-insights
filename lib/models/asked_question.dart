import 'package:json_annotation/json_annotation.dart';

part 'asked_question.g.dart';

@JsonSerializable(fieldRename: FieldRename.snake)
class AskedQuestion {
  final String id;
  final String question;
  final List<String> targetEntityIds;
  final DateTime askedAt;

  const AskedQuestion({
    required this.id,
    required this.question,
    required this.targetEntityIds,
    required this.askedAt,
  });

  factory AskedQuestion.fromJson(Map<String, dynamic> json) =>
      _$AskedQuestionFromJson(json);
  Map<String, dynamic> toJson() => _$AskedQuestionToJson(this);
}
