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
    'PASSKEYS_ENABLED': String.fromEnvironment('PASSKEYS_ENABLED'),
    'CONTEXT_REBUILD_ENABLED':
        String.fromEnvironment('CONTEXT_REBUILD_ENABLED'),
    'CONTEXT_REBUILD_MAX_TURNS':
        String.fromEnvironment('CONTEXT_REBUILD_MAX_TURNS'),
    'CONTEXT_REBUILD_MAX_TOKENS':
        String.fromEnvironment('CONTEXT_REBUILD_MAX_TOKENS'),
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

  /// Passkeys are a Supabase beta and need the Associated Domains entitlement
  /// for the relying-party domain (docs/security/launch-checklist.md section
  /// 9). Off unless the build says `--dart-define=PASSKEYS_ENABLED=true`, so
  /// no button appears that cannot work.
  static bool get passkeysEnabled =>
      (_clean(_defined['PASSKEYS_ENABLED']) ?? '').toLowerCase() == 'true';

  /// EC-01 spike: rebuild Live sessions from saved context at a pause instead
  /// of letting Gemini compress the window. Off unless the build says
  /// `--dart-define=CONTEXT_REBUILD_ENABLED=true`.
  static bool get contextRebuildEnabled =>
      (_clean(_defined['CONTEXT_REBUILD_ENABLED']) ?? '').toLowerCase() ==
      'true';

  /// Turns per session before a rebuild (EC-01): an override for testing;
  /// empty leaves only the token budget.
  static String get contextRebuildMaxTurns =>
      _clean(_defined['CONTEXT_REBUILD_MAX_TURNS']) ?? '';

  /// Window tokens since the last rebuild before the next (EC-05); empty
  /// keeps the default.
  static String get contextRebuildMaxTokens =>
      _clean(_defined['CONTEXT_REBUILD_MAX_TOKENS']) ?? '';
}
