import 'package:flutter_dotenv/flutter_dotenv.dart';

class Env {
  const Env._();

  static Future<void> load() async {
    for (final fileName in const ['.env', 'assets/.env']) {
      try {
        await dotenv.load(fileName: fileName);
        return;
      } catch (_) {
        // Try the next local env location.
      }
    }
    // Local tests and fresh checkouts can run without private credentials.
  }

  static String _first(List<String> keys) {
    for (final key in keys) {
      final value = _clean(dotenv.env[key]);
      if (value != null && value.isNotEmpty) return value;
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

  static String get geminiApiKey =>
      _first(const ['GEMINI_API_KEY', 'VITE_GEMINI_API_KEY']);
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
