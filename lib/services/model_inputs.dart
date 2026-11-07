import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/entity.dart';

/// One conversation turn as the closing card and the brief read it.
typedef InputTurn = ({String speaker, String text, String? spokenAt});

/// What the closing card is written from (LM-56): read on the device, so
/// the names in it can be swapped before it is sent.
class CardInput {
  const CardInput({
    required this.revision,
    required this.turns,
    required this.candidates,
  });

  /// The notebook's revision, read before [turns].
  final int revision;

  /// Oldest first.
  final List<InputTurn> turns;

  /// The notebook's entities the card may remember, most mentioned first.
  final List<Entity> candidates;
}

/// What the session brief is written from (LM-56).
class BriefInput {
  const BriefInput({
    required this.revision,
    required this.turns,
    required this.previous,
    required this.followUps,
    required this.questions,
    required this.topEntities,
    required this.entities,
  });

  final int revision;
  final List<InputTurn> turns;

  /// The stored brief's focus and thread, or null.
  final ({List<String> focus, String openingThread})? previous;
  final List<String> followUps;
  final List<({String name, List<String> questions})> questions;
  final List<({String name, String type})> topEntities;

  /// The entities behind [questions] and [topEntities], for the name map.
  final List<Entity> entities;
}

/// Reads what the model calls need, as the signed-in user (owner-only RLS).
abstract interface class ModelInputSource {
  Future<CardInput> card(String notebookId);
  Future<BriefInput> brief(String notebookId);
}

/// How many remember candidates the app names for the card: the runtime
/// keeps 8 (validate.mjs), chosen by the same order; the rest is slack for
/// ties and for entities the runtime sees differently.
const cardCandidateCount = 20;

/// How much transcript the app sends, newest first: the model reads the
/// last 24 000 characters (validate.mjs limits.transcriptChars).
const transcriptSendChars = 30000;

/// The newest turns, oldest first, up to about [maxChars] of text (always
/// at least the newest turn).
List<InputTurn> recentTurns(List<InputTurn> turns,
    {int maxChars = transcriptSendChars}) {
  final kept = <InputTurn>[];
  var total = 0;
  for (var i = turns.length - 1; i >= 0; i--) {
    total += turns[i].text.length;
    if (kept.isNotEmpty && total > maxChars) break;
    kept.insert(0, turns[i]);
  }
  return kept;
}

class SupabaseModelInputs implements ModelInputSource {
  SupabaseModelInputs(this._client);

  final SupabaseClient _client;

  Future<int> _revision(String notebookId) async {
    final row = await _client
        .from('notebooks')
        .select('revision')
        .eq('id', notebookId)
        .single();
    return (row['revision'] as num).toInt();
  }

  Future<List<InputTurn>> _turns(String notebookId) async {
    final rows = await _client
        .from('conversation_turns')
        .select('speaker, text, spoken_at')
        .eq('notebook_id', notebookId)
        .order('spoken_at', ascending: false)
        .order('turn_id', ascending: false)
        .limit(1000);
    return recentTurns([
      for (final row in rows.reversed)
        (
          speaker: row['speaker'] == 'user' ? 'user' : 'assistant',
          text: row['text'] as String,
          spokenAt: row['spoken_at'] as String?,
        ),
    ]);
  }

  static Entity _entity(Map<String, dynamic> row) => Entity(
        id: row['id'] as String,
        name: row['name'] as String,
        type: EntityType.values.firstWhere(
          (t) => t.name == row['type'],
          orElse: () => EntityType.other,
        ),
        description: row['description'] as String?,
        metadata:
            (row['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
        mentions: (row['mentions'] as num?)?.toInt() ?? 0,
        firstSeen: DateTime.fromMillisecondsSinceEpoch(0),
        lastSeen: DateTime.tryParse('${row['last_seen']}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  @override
  Future<CardInput> card(String notebookId) async {
    // The revision first: a turn saved after it may be missing from the
    // turns, so the card must not claim to cover it.
    final revision = await _revision(notebookId);
    final turns = await _turns(notebookId);
    // The runtime's order (validate.mjs rememberCandidates): mentions, then
    // the most recent, then id.
    final rows = await _client
        .from('entities')
        .select('id, name, type, description, metadata, mentions, last_seen')
        .eq('notebook_id', notebookId)
        .order('mentions', ascending: false)
        .order('last_seen', ascending: false)
        .order('id', ascending: true)
        .limit(cardCandidateCount);
    return CardInput(
      revision: revision,
      turns: turns,
      candidates: [for (final row in rows) _entity(row)],
    );
  }

  @override
  Future<BriefInput> brief(String notebookId) async {
    final revision = await _revision(notebookId);
    final results = await Future.wait<Object?>([
      _turns(notebookId),
      _client.from('session_briefs').select('brief').maybeSingle(),
      _client
          .from('follow_ups')
          .select('question')
          .eq('answered', false)
          .order('created_at', ascending: false)
          .limit(10),
      _client
          .from('entities')
          .select('id, name, type, description, metadata, questions')
          .not('questions', 'is', null)
          .order('last_seen', ascending: false)
          .limit(10),
      _client
          .from('user_entities')
          .select('id, name, type, description, mentions')
          .order('mentions', ascending: false)
          .limit(15),
    ]);
    final turns = results[0] as List<InputTurn>;
    final stored = (results[1] as Map?)?['brief'];
    final followUps = results[2] as List;
    final questionRows = (results[3] as List).cast<Map<String, dynamic>>();
    final topRows = (results[4] as List).cast<Map<String, dynamic>>();

    ({List<String> focus, String openingThread})? previous;
    if (stored is Map) {
      previous = (
        focus: [
          for (final item in (stored['focus'] as List?) ?? const [])
            if (item is String && item.trim().isNotEmpty) item,
        ].take(10).toList(),
        openingThread: (stored['openingThread'] as String?) ?? '',
      );
    }
    return BriefInput(
      revision: revision,
      turns: turns,
      previous: previous,
      followUps: [
        for (final row in followUps)
          if (row['question'] is String &&
              (row['question'] as String).trim().isNotEmpty)
            row['question'] as String,
      ],
      questions: [
        for (final row in questionRows)
          if ((row['questions'] as List?)?.whereType<String>().isNotEmpty ??
              false)
            (
              name: row['name'] as String,
              questions: (row['questions'] as List)
                  .whereType<String>()
                  .where((q) => q.trim().isNotEmpty)
                  .take(20)
                  .toList(),
            ),
      ],
      topEntities: [
        for (final row in topRows)
          (name: row['name'] as String, type: row['type'] as String),
      ],
      entities: [
        for (final row in [...questionRows, ...topRows]) _entity(row),
      ],
    );
  }
}
