import 'dart:convert';
import 'dart:typed_data';

/// How long a stored brief stays worth playing.
const sessionBriefMaxAge = Duration(days: 21);

/// What Lumen says to open a returning user's next session: a short spoken
/// line, synthesized ahead of time, plus the thread it asks about.
class SessionBrief {
  const SessionBrief({
    required this.focus,
    required this.openingThread,
    required this.openingLine,
    required this.createdAt,
    required this.playedAt,
    required this.pcm,
    required this.sampleRate,
  });

  final List<String> focus;
  final String openingThread;
  final String openingLine;

  /// Exactly as the server sent it (microseconds kept): `markPlayed` matches
  /// the row by this instant.
  final DateTime createdAt;
  final DateTime? playedAt;

  /// PCM16 mono audio of [openingLine].
  final Uint8List pcm;
  final int sampleRate;

  factory SessionBrief.fromJson(Map json) {
    final played = json['playedAt'];
    return SessionBrief(
      focus: [for (final f in (json['focus'] as List? ?? const [])) '$f'],
      openingThread: json['openingThread'] as String? ?? '',
      openingLine: json['openingLine'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      playedAt: played is String ? DateTime.parse(played) : null,
      pcm: base64Decode(json['audioBase64'] as String? ?? ''),
      sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 24000,
    );
  }

  /// [sessionBriefMaxAge] (21 days) old or older: its thread is likely
  /// stale, so it is neither played nor sent to the live prompt.
  bool staleAt(DateTime now) => now.difference(createdAt) >= sessionBriefMaxAge;

  /// Unplayed, younger than 21 days, and has audio to play.
  bool usableAt(DateTime now) =>
      playedAt == null && !staleAt(now) && pcm.isNotEmpty;

  SessionBrief copyWith({DateTime? playedAt}) => SessionBrief(
        focus: focus,
        openingThread: openingThread,
        openingLine: openingLine,
        createdAt: createdAt,
        playedAt: playedAt ?? this.playedAt,
        pcm: pcm,
        sampleRate: sampleRate,
      );
}

/// The sign-in lookup: whether the account has history, and its brief if any.
class SessionOpeningState {
  const SessionOpeningState({required this.returning, required this.brief});

  final bool returning;
  final SessionBrief? brief;

  factory SessionOpeningState.fromJson(Map json) {
    final brief = json['brief'];
    return SessionOpeningState(
      returning: json['returning'] == true,
      brief: brief is Map ? SessionBrief.fromJson(brief) : null,
    );
  }
}
