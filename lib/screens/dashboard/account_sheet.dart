import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../env.dart';
import '../../providers/auth_provider.dart';
import '../../providers/journal_provider.dart';
import '../../providers/supabase_provider.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

Future<void> showAccountSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const AccountSheet(),
  );
}

/// Signed-in account details and the ways to leave the account. Navigation
/// after sign-out is owned by the router's auth guard (authRedirect), so this
/// sheet never navigates itself.
class AccountSheet extends ConsumerStatefulWidget {
  const AccountSheet({super.key});

  @override
  ConsumerState<AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends ConsumerState<AccountSheet> {
  bool _busy = false;
  String? _error;

  /// Ends a live journaling session, if one exists, before the account goes
  /// away. Returns false when pending turns are still saving.
  Future<bool> _endLiveSession() async {
    if (!ref.exists(journalProvider)) return true;
    final result = await ref.read(journalProvider.notifier).endSession();
    if (!result.succeeded) {
      if (mounted) setState(() => _error = result.message);
      return false;
    }
    return true;
  }

  Future<void> _signOut() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!await _endLiveSession()) return;
      final service = ref.read(supabaseServiceProvider);
      // Drop this account's in-memory journal state (already saved by
      // endSession) before the sheet unmounts with the signed-in routes.
      ref.invalidate(journalProvider);
      await service.signOut();
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = "Couldn't sign out. Check your connection and try again.");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPrivacyPolicy() async {
    await launchUrl(Uri.parse(Env.privacyPolicyUrl));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final email = ref.watch(authProvider).valueOrNull?.email ?? '';
    final bodyStyle = TextStyle(
      fontFamily: LumenText.sansFontFamily,
      fontSize: 15,
      color: colors.ink,
    );

    const radius = BorderRadius.vertical(top: Radius.circular(16));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            blurRadius: 30,
            color: Colors.black.withValues(alpha: 0.18),
            offset: const Offset(0, -12),
          ),
        ],
      ),
      // Material (not a colored DecoratedBox) so the list tiles' ink shows.
      child: Material(
        color: colors.card,
        borderRadius: radius,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 8),
                    Text('ACCOUNT',
                        style: LumenText.eyebrow(colors.mutedForeground)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      color: colors.mutedForeground,
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Signed in as',
                        style: bodyStyle.copyWith(
                          fontSize: 13,
                          color: colors.mutedForeground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(email, style: bodyStyle),
                    ],
                  ),
                ),
                Divider(color: colors.border, height: 1),
                if (Env.privacyPolicyUrl.isNotEmpty)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Text('Privacy Policy', style: bodyStyle),
                    trailing: Icon(Icons.open_in_new,
                        size: 18, color: colors.mutedForeground),
                    onTap: _busy ? null : _openPrivacyPolicy,
                  ),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  title: Text('Sign out', style: bodyStyle),
                  trailing: _busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.amber,
                          ),
                        )
                      : null,
                  onTap: _busy ? null : _signOut,
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Text(
                      _error!,
                      style: bodyStyle.copyWith(
                        fontSize: 13,
                        color: colors.destructive,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
