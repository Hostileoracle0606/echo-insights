import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic/forget_redaction.dart';
import '../services/pseudonym_store.dart';

/// The people the user forgot (LM-63), as keyed hashes in the Keychain
/// beside the name map. One account's: read at sign-in for the signed-in
/// user only, erased at sign-out.
final forgetRedactorProvider = Provider<ForgetRedactor>((ref) => ForgetRedactor(
      store: KeychainPseudonymStore(null, KeychainPseudonymStore.forgottenKey),
      ownerId: _signedInUserId,
    ));

/// The signed-in user's id, or null when nobody is (or auth isn't up).
String? _signedInUserId() {
  try {
    return Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}
