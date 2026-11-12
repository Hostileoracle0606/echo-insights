// ignore_for_file: experimental_member_use

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../env.dart';
import '../../providers/supabase_provider.dart';
import '../../providers/voice_services_provider.dart';
import '../../security/app_lock_provider.dart';
import '../../services/account_auth_service.dart';
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

/// "Sign-in and devices" in the privacy sheet (LM-58): the devices signed in
/// to this account (this one marked) with remote sign-out, Apple, and
/// passkeys when the build enables them. Everything that changes how someone
/// can get into the account, or ends another device's session, asks for Face
/// ID or the passcode first ([requireReauth]). Loads only when opened.
class SignInSecurity extends ConsumerStatefulWidget {
  const SignInSecurity({super.key, bool? passkeys}) : _passkeys = passkeys;

  final bool? _passkeys;

  @override
  ConsumerState<SignInSecurity> createState() => _SignInSecurityState();
}

class _SignInSecurityState extends ConsumerState<SignInSecurity> {
  bool _loaded = false;
  bool _loading = false;
  String? _problem;
  List<DeviceSession> _devices = const [];
  List<Passkey> _passkeys = const [];
  bool _appleLinked = false;
  String? _busyId;

  bool get _passkeysOn => widget._passkeys ?? Env.passkeysEnabled;

  Future<void> _load() async {
    final service = ref.read(accountAuthServiceProvider);
    setState(() {
      _loading = true;
      _problem = null;
    });
    try {
      final devices = await service.devices();
      final apple = await service.hasAppleLinked();
      final keys = _passkeysOn ? await service.passkeys() : <Passkey>[];
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _appleLinked = apple;
        _passkeys = keys;
      });
    } catch (_) {
      if (mounted) {
        setState(
            () => _problem = 'Could not load this. Check your connection.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _guarded(
    String reason,
    String failure,
    Future<void> Function(AccountAuthService s) action, {
    String? busyId,
  }) async {
    // A failed or cancelled check changes nothing.
    if (!await requireReauth(context, reason: reason)) return;
    if (!mounted) return;
    setState(() {
      _busyId = busyId ?? reason;
      _problem = null;
    });
    try {
      await action(ref.read(accountAuthServiceProvider));
      await _load();
    } catch (_) {
      // Never show the error text: it can carry a token or an address.
      if (mounted) setState(() => _problem = failure);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// Ends this phone's session after Face ID or the passcode, then erases
  /// what the account left on the phone (the same cleanup as a remote
  /// sign-out) and closes the privacy screen; the router shows login. If
  /// signing out fails nothing is erased: the account is still signed in.
  Future<void> _signOutThisPhone() async {
    // Read before any await: the provider is still reachable if this screen
    // is gone by the time sign-out finishes.
    final cleanup = ref.read(signedOutCleanupProvider);
    final service = ref.read(accountAuthServiceProvider);
    if (!await requireReauth(context, reason: 'Sign out of this phone')) return;
    if (!mounted) return;
    setState(() {
      _busyId = 'signOutThisPhone';
      _problem = null;
    });
    try {
      await service.signOutThisDevice();
    } catch (_) {
      // Never show the error text: it can carry a token or an address.
      if (mounted) {
        setState(() {
          _problem = 'Could not sign out. Check your connection.';
          _busyId = null;
        });
      }
      return;
    }
    cleanup();
    if (mounted) {
      setState(() => _busyId = null);
      await Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final small = TextStyle(
      fontFamily: LumenText.sansFontFamily,
      fontSize: 13,
      height: 1.4,
      color: colors.mutedForeground,
    );
    return ExpansionTile(
      key: const Key('signInSecurityTile'),
      tilePadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: colors.ink,
      collapsedIconColor: colors.ink,
      title: const Text('Sign-in and devices'),
      subtitle: Text(
        'Where you are signed in, and how you can sign in.',
        style: small,
      ),
      onExpansionChanged: (open) {
        if (open && !_loaded) {
          _loaded = true;
          _load();
        }
      },
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        if (_problem != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _problem!,
              key: const Key('signInSecurityProblem'),
              style: small.copyWith(color: colors.destructive),
            ),
          ),
        ListTile(
          key: const Key('appleLinkTile'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Sign in with Apple'),
          subtitle: Text(
            _appleLinked
                ? 'Linked to this account.'
                : 'Link your Apple ID to this account so you can sign in '
                    'with it. Asks for Face ID or your passcode first.',
            style: small,
          ),
          trailing: _appleLinked
              ? Icon(Icons.check, color: colors.ink)
              : TextButton(
                  key: const Key('linkAppleButton'),
                  onPressed: _busyId != null
                      ? null
                      : () => _guarded(
                            'Link your Apple ID',
                            'Could not link Apple. It may already belong to '
                                'another account.',
                            (s) async {
                              await s.linkApple();
                            },
                          ),
                  child: const Text('Link'),
                ),
        ),
        if (_passkeysOn) ...[
          for (final key in _passkeys)
            ListTile(
              key: Key('passkey-${key.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text(key.friendlyName ?? 'Passkey'),
              subtitle: Text('Added ${_date(key.createdAt)}', style: small),
              trailing: TextButton(
                onPressed: _busyId != null
                    ? null
                    : () => _guarded(
                          'Remove a passkey',
                          'Could not remove the passkey.',
                          (s) => s.removePasskey(key.id),
                          busyId: key.id,
                        ),
                child: const Text('Remove'),
              ),
            ),
          ListTile(
            key: const Key('addPasskeyTile'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Add a passkey'),
            subtitle: Text(
              'Sign in with Face ID instead of a password. Asks for Face ID '
              'or your passcode first.',
              style: small,
            ),
            trailing: Icon(Icons.add, color: colors.ink),
            onTap: _busyId != null
                ? null
                : () => _guarded(
                      'Add a passkey',
                      'Could not add a passkey.',
                      (s) async {
                        await s.addPasskey();
                      },
                    ),
          ),
        ],
        for (final d in _devices)
          ListTile(
            key: Key('device-${d.id}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.phone_iphone, color: colors.ink),
            title: Text(d.isCurrent ? '${d.kind} (this device)' : d.kind),
            subtitle: Text(
              'Last active ${_date(d.lastActiveAt)}. Signed in '
              '${_date(d.createdAt)}.',
              style: small,
            ),
            trailing: d.isCurrent
                ? null
                : TextButton(
                    key: Key('signOutDevice-${d.id}'),
                    onPressed: _busyId != null
                        ? null
                        : () => _guarded(
                              'Sign out a device',
                              'Could not sign that device out.',
                              (s) async {
                                await s.signOutDevice(d.id);
                              },
                              busyId: d.id,
                            ),
                    child: const Text('Sign out'),
                  ),
          ),
        ListTile(
          key: const Key('signOutThisPhoneTile'),
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.logout, color: colors.ink),
          title: const Text('Sign out of this phone'),
          subtitle: Text(
            'Erases what Lumen keeps on this phone for this account. Your '
            'journal stays in your account. Asks for Face ID or your '
            'passcode first.',
            style: small,
          ),
          onTap: _busyId != null ? null : _signOutThisPhone,
        ),
        if (_devices.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'A device you sign out can\'t renew its sign-in. It may keep '
                'working for up to an hour.',
                style: small,
              ),
            ),
          ),
      ],
    );
  }
}

String _date(DateTime t) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[t.month - 1]} ${t.day}';
}
