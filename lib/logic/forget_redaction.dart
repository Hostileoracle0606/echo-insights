import '../models/entity.dart';
import '../models/journal_entry.dart';
import '../models/journal_state.dart';
import '../models/relation.dart';
import 'memory_removal.dart' show withoutEntity;
import 'slugify.dart';
import 'turn_state.dart' show ConversationTurn;

/// What a forgotten name becomes, as in the database.
const forgottenStandIn = 'someone';

final _word = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);

/// The names of people forgotten while the app runs (LM-63), held in memory
/// only and dropped at sign-out. Lumen's reads from the server are already
/// redacted there; this covers what the app holds or assembles itself: the
/// state before a reload succeeds, this run's turns, the extraction request,
/// the graph summary. It matches the way the server does: the whole name,
/// its words joined by spaces, hyphens, apostrophes or periods, any case;
/// a one-word name only when it starts with a capital.
class ForgetRedactor {
  final Map<String, RegExp> _patterns = {};
  final Set<String> _slugs = {};

  bool get isEmpty => _patterns.isEmpty;

  /// Forgets [id] and every name in [names] (its own, and the names it had
  /// under other ids).
  void add(String id, Iterable<String> names) {
    if (!id.startsWith('e-')) _slugs.add(id);
    for (final name in names) {
      final words = [for (final m in _word.allMatches(name)) m[0]!];
      if (words.isEmpty) continue;
      _slugs.add(slugify(name));
      final key = words.join(' ').toLowerCase();
      _patterns[key] = RegExp(
        '(?<![\\p{L}\\p{M}\\p{N}])'
        '${words.map(RegExp.escape).join("[ \\t'’.\\-]+")}'
        '(?![\\p{L}\\p{M}\\p{N}])',
        caseSensitive: false,
        unicode: true,
      );
    }
  }

  void clear() {
    _patterns.clear();
    _slugs.clear();
  }

  /// [text] with every forgotten name replaced by "someone".
  String redact(String text) {
    if (_patterns.isEmpty || text.isEmpty) return text;
    var out = text;
    // Longest names first, so "Priya Raman" goes before a forgotten "Priya".
    final keys = _patterns.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final key in keys) {
      final oneWord = !key.contains(' ');
      out = out.replaceAllMapped(_patterns[key]!, (m) {
        final first = m[0]!.substring(0, 1);
        if (oneWord && first != first.toUpperCase()) return m[0]!;
        return forgottenStandIn;
      });
    }
    return out;
  }

  bool names(String text) => redact(text) != text;

  /// True when [id] spells a forgotten name ("priya-raman-foundation"): the
  /// server stores that entity under another id, so the app drops this one.
  bool spells(String id) {
    if (_slugs.isEmpty) return false;
    final padded = '-$id-';
    return _slugs.any((slug) => padded.contains('-$slug-'));
  }

  /// [turn] as Lumen may read it: the server's redacted words when it sent
  /// them, then this run's names.
  ConversationTurn turnForLumen(ConversationTurn turn) {
    final text = redact(turn.contextText ?? turn.text);
    if (text == turn.text && turn.contextText == null) return turn;
    return ConversationTurn(
      turnId: turn.turnId,
      role: turn.role,
      text: text,
      createdAt: turn.createdAt,
      startedAt: turn.startedAt,
      input: turn.input,
    );
  }

  /// [state] as the server returns it after the forget: the forgotten
  /// person under any id gone, ids that spell them gone (the server renamed
  /// them), their names redacted in every other text, and questions that
  /// name them dropped. Used at the forget itself, so a failed reload can't
  /// leave their name in what Lumen is sent (BUG-5).
  JournalState redactState(JournalState state) {
    if (isEmpty) return state;
    var next = state;
    for (final e in state.entities.values) {
      if (spells(e.id) || redact(e.name).trim() == forgottenStandIn) {
        next = withoutEntity(next, e.id);
      }
    }
    final dropped = {
      for (final id in state.entities.keys)
        if (!next.entities.containsKey(id)) id,
    };
    return next.copyWith(
      entities: {
        for (final e in next.entities.values) e.id: _entity(e),
      },
      relations: {
        for (final r in next.relations.values)
          r.id: Relation(
            id: r.id,
            source: r.source,
            target: r.target,
            label: r.label,
            metadata: _json(r.metadata) as Map<String, dynamic>,
            createdAt: r.createdAt,
            supersededAt: r.supersededAt,
          ),
      },
      entries: [
        for (final e in next.entries)
          JournalEntry(
            id: e.id,
            text: redact(e.text),
            createdAt: e.createdAt,
            entityIds: e.entityIds,
            relationIds: e.relationIds,
          ),
      ],
      followUps: [
        for (final f in next.followUps)
          if (!names(f.question) &&
              !names(f.reason) &&
              !f.targetEntityIds.any(dropped.contains))
            f,
      ],
    );
  }

  Entity _entity(Entity e) => Entity(
        id: e.id,
        name: redact(e.name),
        type: e.type,
        description: e.description == null ? null : redact(e.description!),
        descriptionSource: e.descriptionSource,
        metadata: _json(e.metadata) as Map<String, dynamic>,
        mentions: e.mentions,
        firstSeen: e.firstSeen,
        lastSeen: e.lastSeen,
        questions: e.questions == null
            ? null
            : [for (final q in e.questions!) redact(q)],
      );

  /// Free-form JSON, keys too, as the server's _jsonb_redact_all.
  Object? _json(Object? value) => switch (value) {
        final String s => redact(s),
        final List<Object?> l => [for (final v in l) _json(v)],
        final Map<Object?, Object?> m => <String, dynamic>{
            for (final e in m.entries) redact('${e.key}'): _json(e.value),
          },
        _ => value,
      };
}
