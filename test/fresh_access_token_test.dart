// At launch Supabase refreshes the session in the background; a request
// made meanwhile carried the expired token and got 401 ("the signed-in
// session is no longer valid"). The token is refreshed first when stale.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/fresh_access_token.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30, 12);
  int epoch(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
  var refreshes = 0;

  Future<String?> token(
    TokenSnapshot? current, {
    TokenSnapshot? refreshed,
    bool refreshThrows = false,
  }) {
    refreshes = 0;
    return freshAccessToken(
      current: () => current,
      refresh: () async {
        refreshes += 1;
        if (refreshThrows) throw StateError('offline');
        return refreshed;
      },
      now: () => now,
    );
  }

  test('a token valid past the margin is used as is', () async {
    final valid = (
      accessToken: 'a',
      expiresAt: epoch(now.add(const Duration(minutes: 10))),
    );
    expect(await token(valid), 'a');
    expect(refreshes, 0);
  });

  test('an expired token is refreshed first', () async {
    final expired = (
      accessToken: 'old',
      expiresAt: epoch(now.subtract(const Duration(minutes: 1))),
    );
    final fresh = (
      accessToken: 'new',
      expiresAt: epoch(now.add(const Duration(hours: 1))),
    );
    expect(await token(expired, refreshed: fresh), 'new');
    expect(refreshes, 1);
  });

  test('a token about to expire counts as stale', () async {
    final closing = (
      accessToken: 'old',
      expiresAt: epoch(now.add(const Duration(seconds: 10))),
    );
    final fresh = (
      accessToken: 'new',
      expiresAt: epoch(now.add(const Duration(hours: 1))),
    );
    expect(await token(closing, refreshed: fresh), 'new');
  });

  test('a failed refresh falls back to the current token', () async {
    final expired = (
      accessToken: 'old',
      expiresAt: epoch(now.subtract(const Duration(minutes: 1))),
    );
    expect(await token(expired, refreshThrows: true), 'old');
  });

  test('signed out: no token and no refresh', () async {
    expect(await token(null), isNull);
    expect(refreshes, 0);
  });
}
