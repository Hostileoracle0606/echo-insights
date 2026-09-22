import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/auth/auth_error_message.dart';
import 'package:lumen/screens/auth/login_screen.dart';
import 'package:lumen/services/supabase_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _ThrowingService implements SupabaseService {
  _ThrowingService(this.error);
  final Object error;

  @override
  Future<void> signInWithEmail(String email, String password) async =>
      throw error;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _submitWith(WidgetTester tester, Object error) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        supabaseServiceProvider.overrideWithValue(_ThrowingService(error)),
      ],
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
  await tester.enterText(find.byType(TextField).first, 'a@b.co');
  await tester.enterText(find.byType(TextField).last, 'pw');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  test('AuthException keeps its user-facing message', () {
    expect(
      authErrorMessage(
        const AuthException('Invalid login credentials'),
        fallback: 'generic',
      ),
      'Invalid login credentials',
    );
  });

  test('any other error is replaced by the fallback', () {
    expect(
      authErrorMessage(
        AssertionError('You must initialize the supabase instance'),
        fallback: 'generic',
      ),
      'generic',
    );
  });

  testWidgets('login shows AuthException text', (tester) async {
    await _submitWith(tester, const AuthException('Invalid login credentials'));
    expect(find.text('Invalid login credentials'), findsOneWidget);
  });

  testWidgets('login never renders SDK internals', (tester) async {
    await _submitWith(
      tester,
      AssertionError('You must initialize the supabase instance'),
    );
    expect(
      find.text("Couldn't sign in. Check your connection and try again."),
      findsOneWidget,
    );
    expect(find.textContaining('initialize'), findsNothing);
  });
}
