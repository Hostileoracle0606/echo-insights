import 'turn_state.dart' show Speaker;

/// EC-04: the state of one conversation, kept outside the Live session so a
/// rebuilt session continues where this one was instead of starting over.
///
/// Built in code from each finalized turn (no model call):
/// - [openThreads]: Lumen's questions still waiting for an answer, newest
///   last. A substantive reply answers the newest; a filler ("hmm") does not.
/// - [pausedTopics]: questions the user set aside ("not now", "later").
/// - [asked]: every question Lumen asked, so it is not asked again.
/// - [commitments]: what Lumen promised ("I'll ask you how it went").
/// - [register]: the user's emotional register from their latest feeling
///   words (stressed, low, upbeat, tired, frustrated).
/// - [covered]: names from the graph that either side has said.
///
/// Callers pass text already redacted for Forget; [redacted] re-applies it
/// when someone is forgotten mid-conversation.
class SessionState {
  const SessionState({
    this.openThreads = const [],
    this.pausedTopics = const [],
    this.asked = const [],
    this.commitments = const [],
    this.register,
    this.covered = const [],
  });

  static const empty = SessionState();

  static const maxOpen = 3;
  static const maxPaused = 5;
  static const maxAsked = 12;
  static const maxCommitments = 5;
  static const maxCovered = 20;

  final List<String> openThreads;
  final List<String> pausedTopics;
  final List<String> asked;
  final List<String> commitments;
  final String? register;
  final List<String> covered;

  bool get isEmpty =>
      openThreads.isEmpty &&
      pausedTopics.isEmpty &&
      asked.isEmpty &&
      commitments.isEmpty &&
      register == null &&
      covered.isEmpty;

  SessionState observe({
    required Speaker speaker,
    required String text,
    required Iterable<String> known,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return this;
    final covered = _newlyCovered(trimmed, known);
    if (speaker == Speaker.assistant) {
      final sentences = _sentences(trimmed);
      final questions = [for (final s in sentences) if (s.endsWith('?')) s];
      final promises = [
        for (final s in sentences)
          if (_promise.hasMatch(s)) s,
      ];
      return _copy(
        openThreads: questions.isEmpty
            ? openThreads
            : _capped([...openThreads.where((q) => q != questions.last), questions.last], maxOpen),
        asked: _capped(_merged(asked, questions), maxAsked),
        commitments: _capped(_merged(commitments, promises), maxCommitments),
        covered: covered,
      );
    }

    var open = openThreads;
    var paused = pausedTopics;
    if (open.isNotEmpty) {
      if (_deflection.hasMatch(trimmed)) {
        paused = _capped(_merged(paused, [open.last]), maxPaused);
        open = open.sublist(0, open.length - 1);
      } else if (_words(trimmed) >= 3) {
        open = open.sublist(0, open.length - 1);
      }
    }
    return _copy(
      openThreads: open,
      pausedTopics: paused,
      register: _registerOf(trimmed) ?? register,
      covered: covered,
    );
  }

  /// Every string with [redact] applied. A covered name that redaction
  /// changes was forgotten: it is dropped, not kept as "someone".
  SessionState redacted(String Function(String) redact) => SessionState(
        openThreads: openThreads.map(redact).toList(),
        pausedTopics: pausedTopics.map(redact).toList(),
        asked: asked.map(redact).toList(),
        commitments: commitments.map(redact).toList(),
        register: register,
        covered: [for (final name in covered) if (redact(name) == name) name],
      );

  Map<String, dynamic> toJson() => {
        'openThreads': openThreads,
        'pausedTopics': pausedTopics,
        'asked': asked,
        'commitments': commitments,
        'register': register,
        'covered': covered,
      };

  /// What the model sees in a rebuilt context. [asked] is already sent as
  /// recentAgentQuestions.
  Map<String, dynamic> toSummary() => {
        'openThreads': openThreads,
        'pausedTopics': pausedTopics,
        'commitments': commitments,
        'register': register,
        'covered': covered,
      };

  /// Empty when [json] is not a stored state: a bad row never breaks a
  /// conversation.
  static SessionState fromJson(Object? json) {
    if (json is! Map) return empty;
    List<String>? strings(Object? value) => value is List && value.every((v) => v is String)
        ? List<String>.unmodifiable(value.cast<String>())
        : null;
    final open = strings(json['openThreads']);
    final paused = strings(json['pausedTopics']);
    final asked = strings(json['asked']);
    final commitments = strings(json['commitments']);
    final covered = strings(json['covered']);
    final register = json['register'];
    if (open == null ||
        paused == null ||
        asked == null ||
        commitments == null ||
        covered == null ||
        (register != null && register is! String)) {
      return empty;
    }
    return SessionState(
      openThreads: open,
      pausedTopics: paused,
      asked: asked,
      commitments: commitments,
      register: register as String?,
      covered: covered,
    );
  }

  SessionState _copy({
    List<String>? openThreads,
    List<String>? pausedTopics,
    List<String>? asked,
    List<String>? commitments,
    String? register,
    List<String>? covered,
  }) =>
      SessionState(
        openThreads: openThreads ?? this.openThreads,
        pausedTopics: pausedTopics ?? this.pausedTopics,
        asked: asked ?? this.asked,
        commitments: commitments ?? this.commitments,
        register: register ?? this.register,
        covered: covered ?? this.covered,
      );

  List<String> _newlyCovered(String text, Iterable<String> known) {
    final lower = text.toLowerCase();
    final hits = <(int, String)>[];
    for (final name in known) {
      final key = name.toLowerCase().trim();
      if (key.length < 2) continue;
      final match = RegExp('(?<![a-z0-9])${RegExp.escape(key)}(?![a-z0-9])').firstMatch(lower);
      if (match != null) hits.add((match.start, name));
    }
    hits.sort((a, b) => a.$1.compareTo(b.$1));
    return _capped(_merged(covered, [for (final hit in hits) hit.$2]), maxCovered);
  }
}

final _promise = RegExp(
  r"\bI(?:'ll|’ll| will) (?:remind|ask|check|follow up|come back|bring)",
  caseSensitive: false,
);

final _deflection = RegExp(
  r"\b(not now|later|another time|rather not|skip (?:it|that|this)|"
  r"don'?t want to (?:talk|get into|go into)|move on|change the subject)\b",
  caseSensitive: false,
);

const _registers = {
  'stressed': ['stressed', 'anxious', 'worried', 'overwhelmed', 'nervous', 'panicking', 'freaking out'],
  'low': ['sad', 'down', 'lonely', 'upset', 'depressed', 'hurt', 'miserable'],
  'upbeat': ['excited', 'happy', 'great', 'thrilled', 'glad', 'proud', 'relieved'],
  'tired': ['tired', 'exhausted', 'drained', 'burnt out', 'burned out', 'sleepy'],
  'frustrated': ['angry', 'frustrated', 'annoyed', 'irritated', 'mad'],
};

/// The register of the feeling word said last in [text], or null.
String? _registerOf(String text) {
  final lower = text.toLowerCase();
  String? best;
  var bestAt = -1;
  _registers.forEach((register, words) {
    for (final word in words) {
      for (final match in RegExp('\\b${RegExp.escape(word)}\\b').allMatches(lower)) {
        if (match.start > bestAt) {
          bestAt = match.start;
          best = register;
        }
      }
    }
  });
  return best;
}

List<String> _sentences(String text) => [
      for (final match in RegExp(r'[^.!?]+[.!?]+|[^.!?]+$').allMatches(text))
        if (match.group(0)!.trim().isNotEmpty) match.group(0)!.trim(),
    ];

int _words(String text) =>
    RegExp(r"[A-Za-z0-9']+").allMatches(text).length;

List<String> _merged(List<String> existing, Iterable<String> incoming) {
  final out = [...existing];
  for (final item in incoming) {
    if (!out.contains(item)) out.add(item);
  }
  return out;
}

List<String> _capped(List<String> items, int max) =>
    List<String>.unmodifiable(items.length <= max ? items : items.sublist(items.length - max));
