// A permanent microphone denial shows a persistent banner (not a SnackBar)
// whose button routes to Settings; with access available, no banner.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/journal_screen.dart';
import 'package:lumen/screens/journal/mic_blocked_banner.dart';
import 'package:lumen/services/mic_permission_service.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _Journal extends JournalNotifier {
  _Journal({required this.blocked});
  final bool blocked;

  @override
  bool get micBlocked => blocked;

  @override
  JournalState build() => JournalState.empty();
}

class _Settings implements MicPermissionService {
  int opened = 0;

  @override
  Future<bool> openSettings() async {
    opened++;
    return true;
  }

  @override
  Future<MicPermission> request() async => MicPermission.permanentlyDenied;

  @override
  Future<MicPermission> status() async => MicPermission.permanentlyDenied;
}

Future<_Settings> _pump(WidgetTester tester, {required bool blocked}) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final settings = _Settings();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        journalProvider.overrideWith(() => _Journal(blocked: blocked)),
        micPermissionServiceProvider.overrideWithValue(settings),
      ],
      child: MaterialApp(
        theme: LumenTheme.light(),
        home: const JournalScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return settings;
}

void main() {
  testWidgets('blocked microphone shows a banner that opens Settings',
      (tester) async {
    final settings = await _pump(tester, blocked: true);

    expect(find.byType(MicBlockedBanner), findsOneWidget);
    expect(find.text('Microphone access is off'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    await tester.tap(find.text('Open Settings'));
    await tester.pump();
    expect(settings.opened, 1);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no banner while the microphone is available', (tester) async {
    await _pump(tester, blocked: false);
    expect(find.byType(MicBlockedBanner), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
