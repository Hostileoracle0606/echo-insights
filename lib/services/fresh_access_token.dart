/// The access token and its expiry (seconds since the epoch), as Supabase
/// reports them. A plain record so the rule below is testable without
/// building a Supabase session.
typedef TokenSnapshot = ({String accessToken, int? expiresAt});

/// Returns an access token the runtime won't reject. At launch Supabase
/// refreshes the session in the background; a token that has expired, or
/// is within [margin] of expiring, is refreshed first. If the refresh
/// fails, the current token is returned and the server decides.
Future<String?> freshAccessToken({
  required TokenSnapshot? Function() current,
  required Future<TokenSnapshot?> Function() refresh,
  Duration margin = const Duration(seconds: 30),
  DateTime Function()? now,
}) async {
  final session = current();
  if (session == null) return null;
  final expiresAt = session.expiresAt;
  final stale = expiresAt == null ||
      DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000, isUtc: true)
          .isBefore((now ?? DateTime.now)().toUtc().add(margin));
  if (!stale) return session.accessToken;
  try {
    return (await refresh())?.accessToken ?? session.accessToken;
  } catch (_) {
    return session.accessToken;
  }
}
