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
    pruneNames: (live) => ref.read(pseudonymServiceProvider).pruneTo(live),
    setBriefTrusted: (ok) =>
        ref.read(openingPrepProvider).setForgetCheckOk(ok),
  );
});

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
  Set<String>? live,
  bool force = true,
}) async {
  try {
    await sync().check(liveEntityIds: live, force: force);
  } catch (error) {
    debugPrint('Forget check not run: ${error.runtimeType}');
  }
}
