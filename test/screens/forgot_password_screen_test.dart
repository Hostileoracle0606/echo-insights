// Password reset, app side: the login link carries the typed email, the
// forgot screen validates before calling Supabase, sends the reset URL as
// redirectTo, and switches to "check your email" with a resend cooldown.
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/auth/forgot_password_screen.dart';
import 'package:lumen/screens/auth/login_screen.dart';
import 'package:lumen/services/supabase_service.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeService implements SupabaseService {
  final requests = <({String email, String? redirectTo})>[];
  Object? error;

  @override
  Future<void> requestPasswordReset(String email, {String? redirectTo}) async {
    requests.add((email: email, redirectTo: redirectTo));
    if (error != null) throw error!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_FakeService> _pump(WidgetTester tester, {String initial = '/auth/forgot'}) async {
  dotenv.testLoad(fileInput: 'PASSWORD_RESET_URL=https://lumen.example/auth/reset');
  final service = _FakeService();
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/auth/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/auth/forgot',
        builder: (_, state) => ForgotPasswordScreen(
          initialEmail: state.extra is String ? state.extra as String : null,
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [supabaseServiceProvider.overrideWithValue(service)],
      child: MaterialApp.router(
        theme: LumenTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

void main() {
  testWidgets('login links to reset and carries the typed email',
      (tester) async {
    await _pump(tester, initial: '/auth/login');

    await tester.enterText(find.byType(TextField).first, ' maya@example.com ');
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(find.byType(ForgotPasswordScreen), findsOneWidget);
    expect(find.text('Reset your password'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'maya@example.com',
    );
  });

  testWidgets('an invalid email is caught before any request', (tester) async {
    final service = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'not-an-email');
    await tester.tap(find.text('Send reset link'));
    await tester.pump();

    expect(find.text('Enter the email address you signed up with.'),
        findsOneWidget);
    expect(service.requests, isEmpty);
  });

  testWidgets('sending shows check-your-email with a resend cooldown',
      (tester) async {
    final service = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'maya@example.com');
    await tester.tap(find.text('Send reset link'));
    await tester.pump();

    expect(service.requests.single.email, 'maya@example.com');
    expect(service.requests.single.redirectTo,
        'https://lumen.example/auth/reset');
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.textContaining('If an account exists for'), findsOneWidget);

    OutlinedButton resend() => tester.widget<OutlinedButton>(
        find.byType(OutlinedButton));
    expect(find.text('Resend link in 60s'), findsOneWidget);
    expect(resend().onPressed, isNull);

    await tester.pump(const Duration(seconds: 60));
    expect(find.text('Resend link'), findsOneWidget);
    expect(resend().onPressed, isNotNull);

    await tester.tap(find.text('Resend link'));
    await tester.pump();
    expect(service.requests, hasLength(2));

    await tester.tap(find.text('Back to sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('a rate limit shows its message; other failures stay generic',
      (tester) async {
    final service = await _pump(tester);
    service.error = const AuthException(
      'For security purposes, you can only request this after 42 seconds.',
      statusCode: '429',
    );

    await tester.enterText(find.byType(TextField), 'maya@example.com');
    await tester.tap(find.text('Send reset link'));
    await tester.pump();
    expect(find.textContaining('after 42 seconds'), findsOneWidget);
    expect(find.text('Check your email'), findsNothing);

    service.error = StateError('socket closed');
    await tester.tap(find.text('Send reset link'));
    await tester.pump();
    expect(
      find.text("Couldn't send the link. Check your connection and try again."),
      findsOneWidget,
    );
    expect(find.textContaining('socket'), findsNothing);
  });
}
