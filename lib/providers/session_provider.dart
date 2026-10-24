import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/turn_state.dart' show ConversationTurn;
import '../models/recall_activity.dart';
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

/// Lumen owns the floor until its session opening has been heard.
final openingInProgressProvider = Provider<bool>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).openingInProgress;
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

/// What Lumen last recalled in this session (entities and quotes, with ids);
/// null until a lookup finds something, and again once the session ends.
/// For citations (LM-13) and recall rings (LM-14).
final recallActivityProvider = Provider<RecallActivity?>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).recall;
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

/// A dropped or recycled connection is being restored by resumption handle.
final reconnectingProvider = Provider<bool>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).reconnecting;
});

/// Lumen joining a new notebook as it opens.
final joiningPhaseProvider = Provider<JoiningPhase>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).joining;
});
