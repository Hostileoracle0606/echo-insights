import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/auth_provider.dart';
import 'providers/voice_services_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/auth/signup_screen.dart';
import 'screens/card/closing_card_screen.dart';
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

final List<RouteBase> appRoutes = [
  GoRoute(path: '/auth/login', builder: (_, __) => const LoginScreen()),
  GoRoute(path: '/auth/signup', builder: (_, __) => const SignupScreen()),
  GoRoute(path: '/dashboard', builder: (_, __) => const DashboardScreen()),
  GoRoute(
    path: '/notebook/:id',
    builder: (_, state) => JournalScreen(
      notebookId: state.pathParameters['id'],
      autoStart: state.uri.queryParameters['start'] == 'true',
      compose: state.uri.queryParameters['compose'] == 'true',
    ),
  ),
  // A sibling, not a child of /notebook/:id: as a child the JournalScreen
  // stayed mounted beneath the card, rebuilt with the card's URL, and
  // re-entered the notebook it had just left (a new one then started a live
  // session, mic open, behind the card).
  GoRoute(
    path: '/notebook/:id/card',
    builder: (_, state) => ClosingCardScreen(
      notebookId: state.pathParameters['id']!,
    ),
  ),
];

final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authProvider);
  return GoRouter(
    initialLocation: '/dashboard',
    redirect: (context, state) => authRedirect(
      isLoggedIn: auth.valueOrNull != null,
      location: state.matchedLocation,
    ),
    routes: appRoutes,
  );
});

class LumenApp extends ConsumerWidget {
  const LumenApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Lumen',
      debugShowCheckedModeBanner: false,
      theme: LumenTheme.light(),
      routerConfig: router,
      builder: (context, child) =>
          VoiceServicesScope(child: child ?? const SizedBox.shrink()),
    );
  }
}
