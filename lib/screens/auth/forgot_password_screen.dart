import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../env.dart';
import '../../providers/supabase_provider.dart';
import '../../theme/lumen_colors.dart';
import 'auth_error_message.dart';

/// Requests a password recovery email, then shows the "check your email"
/// state. The new password is set on the web app's /auth/reset page, which
/// the emailed link opens; the user comes back here and signs in.
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key, this.initialEmail});

  /// Carried over from the login screen so the user doesn't retype it.
  final String? initialEmail;

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  /// Matches Supabase's default per-email throttle on /recover.
  static const resendCooldown = Duration(seconds: 60);

  late final _email = TextEditingController(text: widget.initialEmail ?? '');
  bool _loading = false;
  bool _sent = false;
  String? _error;
  int _cooldownLeft = 0;
  Timer? _cooldown;

  @override
  void dispose() {
    _cooldown?.cancel();
    _email.dispose();
    super.dispose();
  }

  static final _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  Future<void> _send() async {
    final email = _email.text.trim();
    if (!_emailShape.hasMatch(email)) {
      setState(() => _error = 'Enter the email address you signed up with.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref
          .read(supabaseServiceProvider)
          .requestPasswordReset(email, redirectTo: Env.passwordResetUrl);
      if (!mounted) return;
      setState(() => _sent = true);
      _startCooldown();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = authErrorMessage(
          error,
          fallback: "Couldn't send the link. Check your connection and try again.",
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startCooldown() {
    _cooldown?.cancel();
    setState(() => _cooldownLeft = resendCooldown.inSeconds);
    _cooldown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _cooldownLeft--);
      if (_cooldownLeft <= 0) timer.cancel();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final text = Theme.of(context).textTheme;
    final body = text.bodyMedium?.copyWith(
      color: colors.mutedForeground,
      height: 1.5,
    );

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => context.go('/auth/login'),
                      icon: const Icon(Icons.chevron_left),
                      label: const Text('Sign in'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!_sent) ...[
                    Text('Reset your password', style: text.headlineMedium),
                    const SizedBox(height: 8),
                    Text(
                      "Enter the email you signed up with. We'll send a link "
                      'to set a new password.',
                      style: body,
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      autocorrect: false,
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(labelText: 'Email'),
                      onSubmitted: (_) => _send(),
                    ),
                  ] else ...[
                    Text('Check your email', style: text.headlineMedium),
                    const SizedBox(height: 8),
                    Text.rich(
                      TextSpan(
                        children: [
                          const TextSpan(text: 'If an account exists for '),
                          TextSpan(
                            text: _email.text.trim(),
                            style: TextStyle(
                              color: colors.ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const TextSpan(
                            text: ', a reset link is on its way. Open it on any '
                                'device, set a new password, then come back '
                                'here to sign in.',
                          ),
                        ],
                      ),
                      style: body,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(color: colors.destructive),
                    ),
                  ],
                  const SizedBox(height: 20),
                  if (!_sent)
                    FilledButton(
                      onPressed: _loading ? null : _send,
                      child: _loading
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Send reset link'),
                    )
                  else ...[
                    OutlinedButton(
                      onPressed:
                          _loading || _cooldownLeft > 0 ? null : _send,
                      child: Text(
                        _cooldownLeft > 0
                            ? 'Resend link in ${_cooldownLeft}s'
                            : 'Resend link',
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => context.go('/auth/login'),
                      child: const Text('Back to sign in'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
