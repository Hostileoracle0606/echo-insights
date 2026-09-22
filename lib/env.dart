import 'package:flutter_dotenv/flutter_dotenv.dart';

class Env {
  const Env._();

  static Future<void> load() async {
    // Production configuration is supplied with --dart-define or
    // --dart-define-from-file. Private .env files must never be bundled as app
    // assets. Keep dotenv initialized so tests and local tooling can still
    // inject non-production values with dotenv.testLoad.
    if (!dotenv.isInitialized) {
      dotenv.testLoad(fileInput: '');
    }
  }

  static const _defined = <String, String>{
    'NOTEBOOK_RUNTIME_URL': String.fromEnvironment('NOTEBOOK_RUNTIME_URL'),
    'VITE_NOTEBOOK_RUNTIME_URL':
        String.fromEnvironment('VITE_NOTEBOOK_RUNTIME_URL'),
    'SUPABASE_URL': String.fromEnvironment('SUPABASE_URL'),
    'VITE_SUPABASE_URL': String.fromEnvironment('VITE_SUPABASE_URL'),
    'SUPABASE_ANON_KEY': String.fromEnvironment('SUPABASE_ANON_KEY'),
    'SUPABASE_PUBLISHABLE_KEY':
        String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
    'VITE_SUPABASE_PUBLISHABLE_KEY':
        String.fromEnvironment('VITE_SUPABASE_PUBLISHABLE_KEY'),
    'PRIVACY_POLICY_URL': String.fromEnvironment('PRIVACY_POLICY_URL'),
    'PASSWORD_RESET_URL': String.fromEnvironment('PASSWORD_RESET_URL'),
  };

  static String _first(List<String> keys) {
    for (final key in keys) {
      final value = _clean(_defined[key]);
      if (value != null && value.isNotEmpty) return value;
      final dotenvValue = _clean(dotenv.env[key]);
      if (dotenvValue != null && dotenvValue.isNotEmpty) return dotenvValue;
    }
    return '';
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.length < 2) return trimmed;
    final first = trimmed[0];
    final last = trimmed[trimmed.length - 1];
    if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
      return trimmed.substring(1, trimmed.length - 1).trim();
    }
    return trimmed;
  }

  /// Throws a [StateError] naming every missing value. Called at startup so a
  /// build without its --dart-define values fails loudly instead of limping
  /// to a login screen with no backend. Values injected through
  /// `dotenv.testLoad` satisfy it too.
  static void assertConfigured() {
    final missing = [
      if (supabaseUrl.isEmpty) 'SUPABASE_URL',
      if (supabaseAnonKey.isEmpty) 'SUPABASE_ANON_KEY',
      if (notebookRuntimeUrl.isEmpty) 'NOTEBOOK_RUNTIME_URL',
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        'Lumen is missing required configuration: ${missing.join(', ')}. '
        'Build with scripts/ios-build.mjs, which passes them as --dart-define.',
      );
    }
  }

  /// Hosted privacy policy, linked from the account sheet. Required for
  /// signed App Store builds by scripts/ios-build.mjs; optional otherwise.
  static String get privacyPolicyUrl => _first(const ['PRIVACY_POLICY_URL']);

  /// The web app's /auth/reset page, where a recovery link lands. Required
  /// for signed App Store builds by scripts/ios-build.mjs; when empty,
  /// Supabase falls back to the project's Site URL.
  static String get passwordResetUrl => _first(const ['PASSWORD_RESET_URL']);

  static String get notebookRuntimeUrl =>
      _first(const ['NOTEBOOK_RUNTIME_URL', 'VITE_NOTEBOOK_RUNTIME_URL']);
  static String get supabaseUrl =>
      _first(const ['SUPABASE_URL', 'VITE_SUPABASE_URL']);
  static String get supabaseAnonKey => _first(
        const [
          'SUPABASE_ANON_KEY',
          'SUPABASE_PUBLISHABLE_KEY',
          'VITE_SUPABASE_PUBLISHABLE_KEY',
        ],
      );
}
