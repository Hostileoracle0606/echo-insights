import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'journal_provider.dart';

final sessionStatusProvider = Provider<SessionStatus>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).status;
});

final lastTranscriptProvider = Provider<String>((ref) {
  ref.watch(journalProvider);
  return ref.watch(journalProvider.notifier).lastTranscript;
});

final conversationProvider =
    Provider<List<({String role, String text})>>((ref) {
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
