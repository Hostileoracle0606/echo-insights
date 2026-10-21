import 'package:json_annotation/json_annotation.dart';

part 'conversation_mode.g.dart';

/// Which kind of conversation a notebook is (`notebooks.conversation_mode`).
///
/// Not the extraction mode (`wiki` / `granular`), which is a different thing
/// that also happens to be called "mode" on the runtime side.
@JsonEnum(alwaysCreate: true)
enum ConversationMode {
  @JsonValue('weekly_debrief')
  weeklyDebrief,
  @JsonValue('session_prep')
  sessionPrep,
  @JsonValue('what_landed')
  whatLanded,
  @JsonValue('first_session')
  firstSession,
  @JsonValue('just_talk')
  justTalk;

  /// The value stored in SQL and sent over the wire, taken from the
  /// [JsonValue]s above so the strings are spelled in one place.
  String get wireName => _$ConversationModeEnumMap[this]!;
}
