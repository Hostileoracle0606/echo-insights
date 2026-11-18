import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/login_notice_provider.dart';
import '../../providers/supabase_provider.dart';
import '../../providers/voice_services_provider.dart';
import '../../services/account_auth_service.dart';
import '../../services/account_deletion_service.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

/// What the confirmation screen hands back to the privacy sheet when it
/// closes without deleting.
enum DeleteAccountExit { cancelled, export }

/// LM-116: the confirmation for "Delete my account", opened from the privacy
/// sheet after Face ID or the passcode. Says what goes and that it cannot be
/// undone, offers "Export my journal" first, and deletes only on the
/// destructive button. On success it erases what the account left on the
/// phone and returns to the first route; the router shows login with a
/// notice. A failure keeps the person signed in with everything in place.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  bool _deleting = false;
  String? _problem;

  Future<void> _delete() async {
    // A second tap can land before the button rebuilds as disabled.
    if (_deleting) return;
    // Read before any await: signing out rebuilds the router, and this
    // screen may be gone by the time the call returns.
    final service = ref.read(accountDeletionServiceProvider);
    final cleanup = ref.read(signedOutCleanupProvider);
    final notice = ref.read(loginNoticeProvider.notifier);
    final navigator = Navigator.of(context);
    setState(() {
      _deleting = true;
      _problem = null;
    });
    final DeleteOutcome outcome;
    try {
      outcome = await service.deleteAccount();
    } on AccountAuthException catch (e) {
      // A fixed, safe message (never server text): still signed in.
      if (mounted) {
        setState(() {
          _deleting = false;
          _problem = e.message;
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _deleting = false;
          _problem = AccountDeletionService.failure.message;
        });
      }
      return;
    }
    if (outcome == DeleteOutcome.cancelled) {
      // Closed Apple's sheet: nothing was deleted.
      if (mounted) setState(() => _deleting = false);
      return;
    }
    notice.show(
      outcome == DeleteOutcome.deletedAppleNotRevoked
          ? deletedAppleNotRevokedNotice
          : deletedNotice,
    );
    cleanup();
    if (navigator.mounted) navigator.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final body = TextStyle(
      fontFamily: LumenText.sansFontFamily,
      fontSize: 15,
      height: 1.45,
      color: colors.ink,
    );
    return PopScope(
      canPop: !_deleting,
      child: Scaffold(
        backgroundColor: colors.paper,
        appBar: AppBar(
          backgroundColor: colors.paper,
          foregroundColor: colors.ink,
          title: const Text('Delete my account'),
          automaticallyImplyLeading: !_deleting,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Deleting your account erases everything Lumen keeps for '
                  'you: your conversations and their transcripts, your cards, '
                  'your map of people and places, your briefs and what Lumen '
                  'remembers. What Lumen shared, the log kept on this phone, '
                  'is erased too.',
                  style: body,
                ),
                const SizedBox(height: 12),
                Text(
                  'This cannot be undone.',
                  style: body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                Text(
                  'If you signed in with Apple, Apple asks you to confirm once '
                  'more.',
                  style: body.copyWith(color: colors.mutedForeground),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('deleteAccountExportLink'),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: _deleting
                        ? null
                        : () => Navigator.of(context)
                            .pop(DeleteAccountExit.export),
                    child: const Text('Export my journal first'),
                  ),
                ),
                if (_problem != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _problem!,
                    key: const Key('deleteAccountProblem'),
                    style: body.copyWith(color: colors.destructive),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  key: const Key('confirmDeleteAccount'),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.destructive,
                    foregroundColor: colors.destructiveForeground,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _deleting ? null : _delete,
                  child: _deleting
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.destructiveForeground,
                          ),
                        )
                      : Text(_problem == null
                          ? 'Delete my account'
                          : 'Try again'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('cancelDeleteAccount'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _deleting
                      ? null
                      : () => Navigator.of(context)
                          .pop(DeleteAccountExit.cancelled),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
