import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/name_recognizer_channel.dart';
import '../services/pseudonym_service.dart';
import '../services/pseudonym_store.dart';

/// The user's on-device name map (LM-55). Not used by the model calls until
/// LM-56 wires it in; cleared on sign-out (signedOutCleanupProvider) and
/// trimmed when an entity is removed or forgotten.
final pseudonymServiceProvider = Provider<PseudonymService>((ref) {
  return PseudonymService(
    store: KeychainPseudonymStore(),
    recognizer: NativeNameRecognizer(),
  );
});
