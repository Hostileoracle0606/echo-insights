import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/env.dart';

/// LM-127: the repo side of shipping passkeys. The domain and team id are
/// placeholders the owner fills in; these tests keep the three pieces that
/// must agree (AASA file, entitlement, host header rule) from drifting.
void main() {
  test('passkeys stay off unless the build defines PASSKEYS_ENABLED=true', () {
    // `flutter test` passes no dart-define. Release builds opt in (see
    // .github/workflows/flutter-retrieval-release.yml).
    expect(Env.passkeysEnabled, isFalse);
  });

  test('AASA file is valid JSON and names the bundle id', () {
    final file = File('public/.well-known/apple-app-site-association');
    final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final apps = (json['webcredentials'] as Map)['apps'] as List;
    expect(apps, hasLength(1));
    expect(apps.single as String, endsWith('.com.echoinsights.lumen'));
  });

  test('entitlement carries a webcredentials associated domain', () {
    final plist = File('ios/Runner/Runner.entitlements').readAsStringSync();
    expect(plist, contains('com.apple.developer.associated-domains'));
    expect(plist, contains('<string>webcredentials:'));
  });

  test('host is told to serve the AASA file as application/json', () {
    final headers = File('public/_headers').readAsStringSync();
    expect(headers, contains('/.well-known/apple-app-site-association'));
    expect(headers, contains('Content-Type: application/json'));
  });
}
