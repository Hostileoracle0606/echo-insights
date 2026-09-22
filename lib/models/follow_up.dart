import 'package:json_annotation/json_annotation.dart';

part 'follow_up.g.dart';

@JsonSerializable()
class FollowUp {
  final String id;
  final String question;
  final String reason;
  final List<String> targetEntityIds;
  final DateTime createdAt;
  final bool answered;

  const FollowUp({
    required this.id,
    required this.question,
    required this.reason,
    required this.targetEntityIds,
    required this.createdAt,
    required this.answered,
  });

  factory FollowUp.fromJson(Map<String, dynamic> json) =>
      _$FollowUpFromJson(json);
  Map<String, dynamic> toJson() => _$FollowUpToJson(this);
}
