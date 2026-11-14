import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/forget_sync.dart';
import '../services/pseudonym_store.dart';
import 'opening_prep_provider.dart';
import 'pseudonym_provider.dart';
import 'shared_log_provider.dart';
import 'supabase_provider.dart';

/// Brings a forget made on another device to this one (Phase 2, I2): see
/// [ForgetSync].
final forgetSyncProvider = Provider<ForgetSync>((ref) {
  return ForgetSync(
    fetch: () => ref.read(supabaseClientProvider).rpc('forgotten_marker'),
    store: KeychainPseudonymStore(null, forgetMarkerKey),
    ownerId: _signedInUserId,
    clearSharedLog: () => ref.read(sharedLogProvider).forgetPerson(),
    reloadBrief: () => ref.read(openingPrepProvider).reloadOrDropBrief(),
    accountEntityIds: () => _accountEntityIds(ref.read(supabaseClientProvider)),
    pruneNames: (ids) => ref.read(pseudonymServiceProvider).pruneTo(ids),
    setBriefTrusted: (ok) =>
        ref.read(openingPrepProvider).setForgetCheckOk(ok),
  );
});

/// Every entity id in the account (all notebooks), page by page. Throws if
/// any page fails: a partial list must never be pruned against.
Future<Set<String>> _accountEntityIds(SupabaseClient client) async {
  const page = 1000;
  final ids = <String>{};
  for (var from = 0;; from += page) {
    final rows = await client
        .from('user_entities')
        .select('id')
        .order('id')
        .range(from, from + page - 1);
    for (final row in rows) {
      ids.add(row['id'] as String);
    }
    if (rows.length < page) return ids;
  }
}

/// The Keychain item holding the last forgotten-people marker seen.
const forgetMarkerKey = 'privacy.forget_marker';

String? _signedInUserId() {
  try {
    return Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}

/// Runs a [ForgetSync] check from places that must never fail because of it
/// (tests with no Supabase, a provider that can't be built). Pass
/// `() => ref.read(forgetSyncProvider)`.
Future<void> runForgetCheck(
  ForgetSync Function() sync, {
  bool force = true,
}) async {
  try {
    await sync().check(force: force);
  } catch (error) {
    debugPrint('Forget check not run: ${error.runtimeType}');
  }
}
