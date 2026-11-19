import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'env.dart';
import 'providers/deletion_resume.dart';
import 'security/fresh_install.dart';
import 'services/markdown_export.dart';
import 'services/shared_log.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Env.load();

  // A reinstall must not inherit the last install's real names (R31): the
  // Keychain outlives the app, so it is wiped on the first launch.
  await wipeKeychainOnFreshInstall(
    flag: NativeInstallFlag(),
    delete: deleteKeychainItem,
  );

  if (Env.supabaseUrl.isNotEmpty && Env.supabaseAnonKey.isNotEmpty) {
    await Supabase.initialize(
      url: Env.supabaseUrl,
      publishableKey: Env.supabaseAnonKey,
    );
  }

  // Journal exports left in the temporary directory by earlier runs.
  unawaited(sweepStaleExports());
  // Entries in "What Lumen shared" older than 7 days (LM-57).
  unawaited(SharedLog.instance.sweep().catchError((Object _) {}));

  // The app's providers, shared with the launch work below.
  final container = ProviderContainer();
  // A deletion whose "queued" answer never arrived is resent; the phone is
  // wiped only once the server answers (or the session is already gone).
  if (Env.supabaseUrl.isNotEmpty && Env.supabaseAnonKey.isNotEmpty) {
    unawaited(resumePendingDeletion(container));
  }

  runApp(UncontrolledProviderScope(
    container: container,
    child: const LumenApp(),
  ));
}