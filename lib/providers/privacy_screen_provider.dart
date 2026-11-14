import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_provider.dart';
import 'supabase_provider.dart';

/// Whether this account has seen "Who hears you" (profiles.privacy_screen_seen_at,
/// LM-53). Resolves to false on a missing row; an error means "unknown", and
/// callers treat unknown as "don't show": a failed read never blocks the mic.
class PrivacyScreenSeen extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    // Rebuilds for a different account, so one account's answer is never
    // reused for another's.
    final user = ref.watch(authProvider).valueOrNull;
    if (user == null) return true;
    final row = await ref
        .watch(supabaseClientProvider)
        .from('profiles')
        .select('privacy_screen_seen_at')
        .maybeSingle();
    return row?['privacy_screen_seen_at'] != null;
  }

  /// Seen from now on in this session, then recorded server-side. A failed
  /// write is dropped (the screen may show once more next launch).
  Future<void> markSeen() async {
    state = const AsyncData(true);
    try {
      await ref.read(supabaseClientProvider).rpc('mark_privacy_screen_seen');
    } catch (error) {
      debugPrint(
        'Marking the privacy screen seen failed: '
        '${error.runtimeType}',
      );
    }
  }
}

final privacyScreenSeenProvider =
    AsyncNotifierProvider<PrivacyScreenSeen, bool>(PrivacyScreenSeen.new);

/// True when the "Who hears you" screen should be shown before the mic
/// starts. Waits only briefly for an unresolved read, and an error or a
/// timeout means no.
Future<bool> shouldShowPrivacyScreen(WidgetRef ref) async {
  final current = ref.read(privacyScreenSeenProvider);
  if (current.hasValue) return !current.requireValue;
  if (current.hasError) return false;
  try {
    final seen = await ref
        .read(privacyScreenSeenProvider.future)
        .timeout(const Duration(seconds: 2));
    return !seen;
  } catch (_) {
    return false;
  }
}
