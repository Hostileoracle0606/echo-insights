import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/app.dart';

void main() {
  group('authRedirect', () {
    test('sends authenticated users from auth screens to the dashboard', () {
      expect(
        authRedirect(isLoggedIn: true, location: '/auth/login'),
        '/dashboard',
      );
      expect(
        authRedirect(isLoggedIn: true, location: '/auth/signup'),
        '/dashboard',
      );
    });

    test('sends signed-out users from protected screens to login', () {
      expect(
        authRedirect(isLoggedIn: false, location: '/dashboard'),
        '/auth/login',
      );
      expect(
        authRedirect(isLoggedIn: false, location: '/notebook/notebook-1'),
        '/auth/login',
      );
    });

    test('does not redirect users already in the correct route family', () {
      expect(
        authRedirect(isLoggedIn: true, location: '/dashboard'),
        isNull,
      );
      expect(
        authRedirect(isLoggedIn: false, location: '/auth/login'),
        isNull,
      );
    });
  });
}
