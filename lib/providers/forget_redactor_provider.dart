import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/forget_redaction.dart';

/// The names forgotten while the app runs (LM-63). One account's, in memory
/// only: sign-out clears it.
final forgetRedactorProvider =
    Provider<ForgetRedactor>((ref) => ForgetRedactor());
