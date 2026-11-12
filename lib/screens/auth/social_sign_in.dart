import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../env.dart';
import '../../providers/opening_prep_provider.dart';
import '../../providers/supabase_provider.dart';
import '../../services/account_auth_service.dart';

/// "Sign in with Apple" (Apple's own button, per its guidelines) and, when
/// the build enables them, passkeys. Shared by the login and signup screens.
/// A new account goes the same way as email signup: [markNewAccount] so the
/// first session gets the intro. A cancelled sheet shows nothing.
class SocialSignInButtons extends ConsumerStatefulWidget {
  const SocialSignInButtons({
    super.key,
    required this.signup,
    bool? passkeys,
  }) : _passkeys = passkeys;

  /// Signup says "Sign up with Apple"; login says "Sign in with Apple".
  final bool signup;
  final bool? _passkeys;

  @override
  ConsumerState<SocialSignInButtons> createState() =>
      _SocialSignInButtonsState();
}

class _SocialSignInButtonsState extends ConsumerState<SocialSignInButtons> {
  bool _busy = false;
  String? _error;

  Future<void> _run(
    Future<SignInOutcome> Function(AccountAuthService s) action,
    String failure,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await action(ref.read(accountAuthServiceProvider));
      if (outcome == SignInOutcome.newAccount) {
        ref.read(openingPrepProvider).markNewAccount();
      }
    } on AccountAuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      // Never show the error text: it can carry a token or an address.
      if (mounted) setState(() => _error = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final showPasskey =
        !widget.signup && (widget._passkeys ?? Env.passkeysEnabled);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Apple's guidelines: its button, black on light and white on dark,
        // at least as prominent as the other options, 44pt or taller.
        Opacity(
          opacity: _busy ? 0.5 : 1,
          child: SignInWithAppleButton(
            key: const Key('appleSignInButton'),
            text: widget.signup ? 'Sign up with Apple' : 'Sign in with Apple',
            style: dark
                ? SignInWithAppleButtonStyle.white
                : SignInWithAppleButtonStyle.black,
            height: 48,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            onPressed: () {
              if (_busy) return;
              _run(
                (s) => s.signInWithApple(),
                'Could not sign in with Apple. Try again.',
              );
            },
          ),
        ),
        if (showPasskey) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('passkeySignInButton'),
            onPressed: _busy
                ? null
                : () => _run(
                      (s) => s.signInWithPasskey(),
                      'Could not sign in with a passkey. Try again, or use '
                      'your email.',
                    ),
            icon: const Icon(Icons.key_outlined),
            label: const Text('Sign in with a passkey'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const Key('socialSignInError'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('or', style: Theme.of(context).textTheme.bodySmall),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
