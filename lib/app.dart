import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/auth_provider.dart';
import 'providers/journal_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/dashboard/dashboard_screen.dart';
import 'screens/journal/journal_screen.dart';
import 'theme/lumen_theme.dart';

String? authRedirect({
  required bool isLoggedIn,
  required String location,
}) {
  final isAuthRoute = location.startsWith('/auth');
  if (!isLoggedIn && !isAuthRoute) return '/auth/login';
  if (isLoggedIn && isAuthRoute) return '/dashboard';
  return null;
}

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authProvider);
  return GoRouter(
    initialLocation: '/dashboard',
    redirect: (context, state) => authRedirect(
      isLoggedIn: auth.valueOrNull != null,
      location: state.matchedLocation,
    ),
    routes: [
      GoRoute(path: '/auth/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/auth/signup', builder: (_, __) => const SignupScreen()),
      GoRoute(path: '/dashboard', builder: (_, __) => const DashboardScreen()),
      GoRoute(
        path: '/notebook/:id',
        builder: (_, state) => JournalScreen(
          notebookId: state.pathParameters['id'],
          autoStart: state.uri.queryParameters['start'] == 'true',
        ),
      ),
    ],
  );
});

class LumenApp extends ConsumerStatefulWidget {
  const LumenApp({super.key});

  @override
  ConsumerState<LumenApp> createState() => _LumenAppState();
}

class _LumenAppState extends ConsumerState<LumenApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onStateChange: _onLifecycleChange);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _onLifecycleChange(AppLifecycleState lifecycle) {
    // Only an existing journal can hold a live session; never build one here.
    if (!ref.exists(journalProvider)) return;
    ref.read(journalProvider.notifier).handleAppLifecycle(lifecycle);
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Lumen',
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      routerConfig: router,
    );
  }
}
