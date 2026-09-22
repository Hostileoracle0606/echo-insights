// Account sheet: reachable from the dashboard hero, shows who is signed in,
// and signing out hands navigation to the router's auth guard, which lands
// on the login screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/app.dart';
import 'package:lumen/models/notebook.dart';
import 'package:lumen/providers/auth_provider.dart';
import 'package:lumen/providers/notebooks_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/auth/login_screen.dart';
import 'package:lumen/screens/dashboard/account_sheet.dart';
import 'package:lumen/services/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Signing out emits a null user on the auth stream, as Supabase does.
class _FakeSupabaseService extends SupabaseService {
  _FakeSupabaseService(this._auth)
      : super(
          SupabaseClient(
            'https://example.supabase.co',
            'anon-key',
            authOptions: const AuthClientOptions(autoRefreshToken: false),
          ),
        );

  final StreamController<User?> _auth;
  int signOutCalls = 0;

  @override
  Future<void> signOut() async {
    signOutCalls++;
    _auth.add(null);
  }
}

const _user = User(
  id: 'user-1',
  appMetadata: {},
  userMetadata: {},
  aud: 'authenticated',
  email: 'reviewer@example.com',
  createdAt: '2026-09-22T00:00:00Z',
);

Future<void> _frames(WidgetTester tester, [int n = 60]) async {
  // The hero's amber pulse repeats forever, so never pumpAndSettle.
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('account sheet shows the email and signing out returns to login',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    dotenv.testLoad(
        fileInput: 'PRIVACY_POLICY_URL=https://example.com/privacy');

    final auth = StreamController<User?>();
    addTearDown(auth.close);
    auth.add(_user);
    final service = _FakeSupabaseService(auth);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => auth.stream),
          supabaseServiceProvider.overrideWithValue(service),
          notebooksProvider.overrideWith((ref) => <Notebook>[]),
        ],
        child: const LumenApp(),
      ),
    );
    await _frames(tester);
    expect(find.byType(LoginScreen), findsNothing);

    await tester.tap(find.byTooltip('Account'));
    await _frames(tester, 30);

    expect(find.byType(AccountSheet), findsOneWidget);
    expect(find.text('Signed in as'), findsOneWidget);
    expect(find.text('reviewer@example.com'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);

    await tester.tap(find.text('Sign out'));
    await _frames(tester, 30);

    expect(service.signOutCalls, 1);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(AccountSheet), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
