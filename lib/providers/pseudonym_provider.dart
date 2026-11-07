import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/name_recognizer_channel.dart';
import '../services/pseudonym_service.dart';
import '../services/pseudonym_store.dart';

/// The user's on-device name map (LM-55). Not used by the model calls until
/// LM-56 wires it in; cleared on sign-out (signedOutCleanupProvider) and
/// trimmed when an entity is removed or forgotten.
final pseudonymServiceProvider = Provider<PseudonymService>((ref) {
  return PseudonymService(
    ownerId: _signedInUserId,
    store: KeychainPseudonymStore(),
    recognizer: NativeNameRecognizer(),
  );
});

/// The signed-in user's id, or null when nobody is (or auth isn't up).
String? _signedInUserId() {
  try {
    return Supabase.instance.client.auth.currentUser?.id;
  } catch (_) {
    return null;
  }
}
