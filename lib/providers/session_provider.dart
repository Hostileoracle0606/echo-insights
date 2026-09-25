import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/turn_state.dart' show ConversationTurn;
import '../models/upsert_activity.dart';
import 'journal_provider.dart';

final sessionStatusProvider = Provider<SessionStatus>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).status;
});

/// The user's in-flight words; empty once the turn finalizes.
final liveUserTextProvider = Provider<String>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).liveUserText;
});

/// Lumen's streaming words; empty once the assistant turn completes.
final liveAgentTextProvider = Provider<String>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).liveAgentText;
});

/// Finalized and unfinished turns in the order they were spoken.
final transcriptRowsProvider = Provider<List<TranscriptRow>>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).transcriptRows;
});

/// A finalized turn is still being extracted/committed (web: "Mapping").
final extractingProvider = Provider<bool>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).extracting;
});

/// The most recent upsert, visible for ~5.2s (web: the "Upserting" chip).
final upsertActivityProvider = Provider<UpsertActivity?>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).activity;
});

final conversationProvider = Provider<List<ConversationTurn>>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).conversation;
});

final mutedProvider = Provider<bool>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).muted;
});

final agentSpeakingProvider = Provider<bool>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).agentSpeaking;
});
