import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/account_deletion_service.dart';
import 'login_notice_provider.dart';
import 'supabase_provider.dart';

/// Per-launch: resends an account deletion whose "queued" answer never
/// arrived (the "deletion pending" marker). Once the server answers queued,
/// or the session is already gone, the phone is wiped like after a delete
/// from the confirmation screen and login shows
/// the deleted notice. Anything else leaves the phone as it is. Never throws.
Future<DeleteOutcome?> resumePendingDeletion(
    ProviderContainer container) async {
  try {
    final outcome =
        await container.read(accountDeletionServiceProvider).resumePending();
    if (outcome == null || outcome == DeleteOutcome.cancelled) return null;
    container.read(loginNoticeProvider.notifier).show(
          outcome == DeleteOutcome.deletedAppleNotRevoked
              ? deletedAppleNotRevokedNotice
              : deletedNotice,
        );
    return outcome;
  } catch (error) {
    // The type only: never a token, an id or server text.
    debugPrint('Pending deletion not resumed: ${error.runtimeType}');
    return null;
  }
}
