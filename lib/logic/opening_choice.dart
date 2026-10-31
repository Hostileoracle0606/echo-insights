import '../models/session_brief.dart';

enum OpeningChoice { intro, brief, fallback }

/// Which opening to play when a new notebook starts. Never waits on
/// anything: [state] is whatever the sign-in load had by now.
///
/// - a known returning account never gets the intro, even if this app run
///   signed up (Supabase's signUp "succeeds" on an existing email when
///   confirmation is on);
/// - an account signed up in this app run gets the intro;
/// - unknown state means fallback (never the intro for a returning user);
/// - a known new account gets the intro;
/// - a usable brief plays; otherwise the fallback clip.
OpeningChoice chooseOpening({
  required SessionOpeningState? state,
  required bool knownNewAccount,
  required DateTime now,
}) {
  if (knownNewAccount && state?.returning != true) return OpeningChoice.intro;
  if (state == null) return OpeningChoice.fallback;
  if (!state.returning) return OpeningChoice.intro;
  final brief = state.brief;
  if (brief != null && brief.usableAt(now)) return OpeningChoice.brief;
  return OpeningChoice.fallback;
}
