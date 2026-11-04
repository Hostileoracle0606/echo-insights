// LM-51: the "Keep transcripts for…" choice, and the one-time offer after the
// third finished session.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/retention_offer.dart';
import 'package:lumen/models/notebook.dart';
import 'package:lumen/providers/notebooks_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/screens/dashboard/dashboard_screen.dart';
import 'package:lumen/services/transcript_retention_service.dart';
import 'package:lumen/theme/lumen_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Fake {
  _Fake(this.value);
  int? value;
  final calls = <Map<String, dynamic>>[];
  bool failSet = false;

  TranscriptRetentionService get service =>
      TranscriptRetentionService.withFunctions(
        read: () async => value,
        rpc: (fn, params) async {
          expect(fn, 'set_transcript_retention');
          if (failSet) throw StateError('nope');
          calls.add(params);
          value = params['p_days'] as int?;
          return value;
        },
      );
}

Notebook _nb(int i, {required bool done}) {
  final started = DateTime.now().subtract(Duration(days: i + 1));
  return Notebook(
    id: 'n$i',
    userId: 'u',
    title: 'Session $i',
    titleSource: 'ai',
    startedAt: started,
    endedAt: done ? started.add(const Duration(minutes: 10)) : null,
    entityCount: 1,
    createdAt: started,
    updatedAt: started,
  );
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  _Fake fake,
  List<Notebook> notebooks,
) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        notebooksProvider.overrideWith((ref) => notebooks),
        transcriptRetentionServiceProvider.overrideWithValue(fake.service),
      ],
      child: MaterialApp(
        theme: LumenTheme.light(),
        home: const DashboardScreen(),
      ),
    ),
  );
  for (var i = 0; i < 90; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  test('offer is due from the third finished session, once', () {
    expect(shouldOfferRetention(completedSessions: 2, alreadyOffered: false),
        isFalse);
    expect(shouldOfferRetention(completedSessions: 3, alreadyOffered: false),
        isTrue);
    expect(shouldOfferRetention(completedSessions: 9, alreadyOffered: true),
        isFalse);
  });

  testWidgets('the third finished session offers the choice once',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fake = _Fake(null);
    final three = [for (var i = 0; i < 3; i++) _nb(i, done: true)];

    await _pumpDashboard(tester, fake, three);
    expect(find.text('Keep transcripts for…'), findsOneWidget);
    expect(find.text('Cards and what Lumen remembers stay.'), findsOneWidget);
    for (final label in ['Forever', '90 days', '30 days', '7 days']) {
      expect(find.text(label), findsOneWidget);
    }

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(retentionOfferedKey), isTrue);

    // Dismiss, then come back to the dashboard: no second offer.
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await _pumpDashboard(tester, fake, three);
    expect(find.text('Keep transcripts for…'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('two finished sessions, or one still live, do not offer',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpDashboard(tester, _Fake(null), [
      _nb(0, done: true),
      _nb(1, done: true),
      _nb(2, done: false),
    ]);
    expect(find.text('Keep transcripts for…'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a choice goes through the setter; the current one is marked',
      (tester) async {
    SharedPreferences.setMockInitialValues({retentionOfferedKey: true});
    final fake = _Fake(90);
    await _pumpDashboard(tester, fake, [_nb(0, done: true)]);

    await tester.tap(find.byKey(const Key('privacySettingsButton')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Keep transcripts for…'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.byKey(const Key('retention-7')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.calls, [
      {'p_days': 7}
    ]);

    await tester.tap(find.byKey(const Key('retention-forever')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.calls.last, {'p_days': null});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed save says so and keeps the old choice', (tester) async {
    SharedPreferences.setMockInitialValues({retentionOfferedKey: true});
    final fake = _Fake(30)..failSet = true;
    await _pumpDashboard(tester, fake, [_nb(0, done: true)]);

    await tester.tap(find.byKey(const Key('privacySettingsButton')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('retention-7')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text("Couldn't save that. Try again."), findsOneWidget);
    expect(fake.value, 30);
    await tester.pumpWidget(const SizedBox());
  });
}
