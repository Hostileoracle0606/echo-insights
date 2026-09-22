import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../env.dart';
import 'supabase_provider.dart';

final authProvider = StreamProvider<User?>((ref) {
  if (Env.supabaseUrl.isEmpty || Env.supabaseAnonKey.isEmpty) {
    return Stream<User?>.value(null);
  }
  final client = ref.watch(supabaseClientProvider);
  return client.auth.onAuthStateChange.map((event) => event.session?.user);
});

/// The signed-in user's first name for greetings, or '' when there's no good
/// name to show (so callers can fall back to an un-personalized greeting).
final displayNameProvider = Provider<String>((ref) {
  return _firstName(ref.watch(authProvider).valueOrNull);
});

String _firstName(User? user) {
  final meta = user?.userMetadata;
  for (final key in const ['name', 'full_name', 'display_name']) {
    final value = meta?[key];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim().split(' ').first;
    }
  }
  final email = user?.email;
  if (email != null && email.contains('@')) {
    final handle = email.split('@').first.split(RegExp(r'[._+-]')).first;
    if (handle.isNotEmpty && handle.length <= 14) {
      return handle[0].toUpperCase() + handle.substring(1);
    }
  }
  return '';
}
