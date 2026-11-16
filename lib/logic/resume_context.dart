import '../models/journal_entry.dart';
import '../services/gemini_live_client.dart' show HistoryTurn;
import 'turn_state.dart';

/// Sent after the earlier turns when a notebook's conversation continues
/// (plan: Flow 4). The system instruction never changes between sessions.
const resumeNote = "(This continues an earlier conversation in this "
    "notebook. Don't greet me or recap it; wait for me to speak.)";

/// Whether a session in this notebook continues an earlier conversation
/// (no greeting, context seeded) rather than starting one.
bool continuesConversation({
  required List<ConversationTurn> conversation,
  required List<JournalEntry> entries,
}) =>
    conversation.isNotEmpty || entries.isNotEmpty;

/// The most recent context that fits: this run's finalized turns when there
/// are any, otherwise the notebook's saved journal entries (the user's own
/// words). Newest last, at most [maxTurns] turns and [maxChars] characters
/// (~2,000 tokens).
List<HistoryTurn> resumeContext({
  required List<ConversationTurn> conversation,
  required List<JournalEntry> entries,
  int maxTurns = 20,
  int maxChars = 8000,
}) {
  final candidates = conversation.isNotEmpty
      ? [
          for (final turn in conversation)
            (fromUser: turn.role == Speaker.user, text: turn.text.trim()),
        ]
      : [
          for (final entry in [...entries]
            ..sort((a, b) => a.createdAt.compareTo(b.createdAt)))
            (fromUser: true, text: entry.text.trim()),
        ];
  final picked = <HistoryTurn>[];
  var chars = 0;
  for (final turn in candidates.reversed) {
    if (turn.text.isEmpty) continue;
    if (picked.length >= maxTurns || chars + turn.text.length > maxChars) {
      break;
    }
    picked.add(turn);
    chars += turn.text.length;
  }
  return picked.reversed.toList(growable: false);
}
