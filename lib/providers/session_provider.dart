import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/turn_state.dart' show ConversationTurn;
import 'journal_provider.dart';

final sessionStatusProvider = Provider<SessionStatus>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).status;
});

final lastTranscriptProvider = Provider<String>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).lastTranscript;
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

final micBlockedProvider = Provider<bool>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).micBlocked;
});
