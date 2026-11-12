// LM-58: the Apple and passkey buttons on the login and signup screens.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/auth_provider.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/auth/login_screen.dart';
import 'package:lumen/screens/auth/signup_screen.dart';
import 'package:lumen/screens/auth/social_sign_in.dart';
import 'package:lumen/services/account_auth_service.dart';
import 'package:lumen/services/session_brief_service.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/fake_auth_gateway.dart';

void main() {
  late FakeAuthGateway gateway;
  late AppleCredential? apple;
  late Object? appleError;
  late OpeningPrep prep;

  setUp(() {
    gateway = FakeAuthGateway();
    apple = const AppleCredential(identityToken: 'apple-id-token');
    appleError = null;
    prep = OpeningPrep(
      SessionBriefService(
        baseUrl: 'http://localhost',
        accessTokenProvider: () async => null,
        rpc: (fn, [params]) async => null,
      ),
    );
  });

  Future<void> pump(
    WidgetTester t,
    Widget screen, {
    bool passkeys = false,
    Brightness brightness = Brightness.light,
  }) async {
    final service = AccountAuthService(
      gateway,
      appleCredential: (_) async {
        if (appleError != null) throw appleError!;
        return apple;
      },
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          accountAuthServiceProvider.overrideWithValue(service),
          openingPrepProvider.overrideWithValue(prep),
        ],
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? ThemeData.dark()
              : LumenTheme.light(),
          home: screen,
        ),
      ),
    );
  }

  final apple_ = find.byKey(const Key('appleSignInButton'));

  group('login', () {
    testWidgets('shows Apple\'s button with its standard wording', (t) async {
      await pump(t, const LoginScreen());

      expect(apple_, findsOneWidget);
      expect(find.text('Sign in with Apple'), findsOneWidget);
      expect(t.getSize(apple_).height, greaterThanOrEqualTo(44));
      expect(find.byKey(const Key('passkeySignInButton')), findsNothing,
          reason: 'passkeys stay hidden until the build enables them');
    });

    testWidgets('an existing account signs in and is not marked new',
        (t) async {
      await pump(t, const LoginScreen());

      await t.tap(apple_);
      await t.pumpAndSettle();

      expect(gateway.signedInToken, 'apple-id-token');
      expect(prep.knownNewAccount, isFalse);
      expect(find.byKey(const Key('socialSignInError')), findsNothing);
    });

    testWidgets('a cancelled Apple sheet shows no error', (t) async {
      apple = null;
      await pump(t, const LoginScreen());

      await t.tap(apple_);
      await t.pumpAndSettle();

      expect(find.byKey(const Key('socialSignInError')), findsNothing);
      expect(gateway.calls, isEmpty);
    });

    testWidgets('a failure shows a plain message, never the error text',
        (t) async {
      gateway.signInError = const AuthException('secret-token-abc a@b.com');
      await pump(t, const LoginScreen());

      await t.tap(apple_);
      await t.pumpAndSettle();

      expect(find.text('Could not sign in with Apple. Try again.'),
          findsOneWidget);
      expect(find.textContaining('secret-token'), findsNothing);
      expect(find.textContaining('a@b.com'), findsNothing);
    });

    testWidgets('Apple throwing (not a cancel) is the same plain message',
        (t) async {
      appleError = StateError('boom');
      await pump(t, const LoginScreen());

      await t.tap(apple_);
      await t.pumpAndSettle();

      expect(find.text('Could not sign in with Apple. Try again.'),
          findsOneWidget);
    });

    testWidgets('a missing token reads as a retryable message', (t) async {
      apple = const AppleCredential(identityToken: null);
      await pump(t, const LoginScreen());

      await t.tap(apple_);
      await t.pumpAndSettle();

      expect(find.text('Apple did not return a sign-in.'), findsOneWidget);
    });

    testWidgets('the passkey button appears when enabled and signs in',
        (t) async {
      await pump(
        t,
        const Scaffold(
            body: SocialSignInButtons(signup: false, passkeys: true)),
      );
      gateway.passkeyResponse = AuthResponse(user: fakeUser());

      await t.tap(find.byKey(const Key('passkeySignInButton')));
      await t.pumpAndSettle();

      expect(gateway.calls, ['signInWithPasskey']);
    });

    testWidgets('a cancelled passkey prompt shows no error', (t) async {
      await pump(
        t,
        const Scaffold(
            body: SocialSignInButtons(signup: false, passkeys: true)),
      );
      gateway.passkeyResponse = null;

      await t.tap(find.byKey(const Key('passkeySignInButton')));
      await t.pumpAndSettle();

      expect(find.byKey(const Key('socialSignInError')), findsNothing);
    });

    testWidgets('a passkey failure shows a plain message', (t) async {
      await pump(
        t,
        const Scaffold(
            body: SocialSignInButtons(signup: false, passkeys: true)),
      );
      gateway.signInError = const AuthException('passkey_disabled');

      await t.tap(find.byKey(const Key('passkeySignInButton')));
      await t.pumpAndSettle();

      expect(find.textContaining('Could not sign in with a passkey'),
          findsOneWidget);
      expect(find.textContaining('passkey_disabled'), findsNothing);
    });

    testWidgets('renders in dark mode', (t) async {
      await pump(t, const LoginScreen(), brightness: Brightness.dark);
      expect(apple_, findsOneWidget);
    });
  });

  group('signup', () {
    testWidgets('says Sign up with Apple and has no passkey button', (t) async {
      await pump(t, const SignupScreen());

      expect(find.text('Sign up with Apple'), findsOneWidget);
      expect(find.byKey(const Key('passkeySignInButton')), findsNothing);
    });

    testWidgets('a new Apple account goes the email-signup way: marked new',
        (t) async {
      gateway.response = AuthResponse(
        user: fakeUser(
          created: DateTime.now().toUtc(),
          lastSignIn: DateTime.now().toUtc(),
        ),
      );
      await pump(t, const SignupScreen());

      await t.tap(apple_);
      await t.pumpAndSettle();

      expect(prep.knownNewAccount, isTrue);
    });

    testWidgets('a cancelled sheet leaves the account unmarked', (t) async {
      apple = null;
      await pump(t, const SignupScreen());

      await t.tap(apple_);
      await t.pumpAndSettle();

      expect(prep.knownNewAccount, isFalse);
    });
  });

  group('greeting', () {
    test('a hidden Apple email is never used as a name', () {
      final user = fakeUser(email: 'abc123xyz@privaterelay.appleid.com');
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith((ref) => Stream.value(user)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(authProvider, (_, __) {});
      return Future<void>.delayed(Duration.zero).then((_) {
        expect(container.read(displayNameProvider), '');
      });
    });
  });
}
