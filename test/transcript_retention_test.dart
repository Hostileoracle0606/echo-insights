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

class _Fake {
  _Fake(this.value, {this.offered = false});
  int? value;
  bool offered;
  int marks = 0;
  bool unreadable = false;
  final calls = <Map<String, dynamic>>[];
  bool failSet = false;

  TranscriptRetentionService get service =>
      TranscriptRetentionService.withFunctions(
        read: () async {
          if (unreadable) throw StateError('offline');
          return {
            'transcript_retention_days': value,
            'transcript_retention_offered_at': offered ? 'then' : null,
          };
        },
        rpc: (fn, params) async {
          if (fn == 'mark_transcript_retention_offered') {
            marks++;
            offered = true;
            return null;
          }
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

/// The one way in: the privacy button, then the transcripts row.
Future<void> _openRetention(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('privacyButton')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.byKey(const Key('transcriptRetentionTile')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
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
    final fake = _Fake(null);
    final three = [for (var i = 0; i < 3; i++) _nb(i, done: true)];

    await _pumpDashboard(tester, fake, three);
    expect(find.text('Keep transcripts for…'), findsOneWidget);
    expect(find.text('Cards and what Lumen remembers stay.'), findsOneWidget);
    for (final label in ['Forever', '90 days', '30 days', '7 days']) {
      expect(find.text(label), findsOneWidget);
    }

    // Recorded on the account once the sheet is up.
    expect(fake.marks, 1);
    expect(fake.offered, isTrue);

    // Dismiss, then come back to the dashboard: no second offer.
    await tester.tap(find.text('Done'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await _pumpDashboard(tester, fake, three);
    expect(find.text('Keep transcripts for…'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an account that was already offered (another device) is not',
      (tester) async {
    final fake = _Fake(null, offered: true);
    await _pumpDashboard(
        tester, fake, [for (var i = 0; i < 4; i++) _nb(i, done: true)]);
    expect(find.text('Keep transcripts for…'), findsNothing);
    expect(fake.marks, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an unreadable profile offers nothing and marks nothing',
      (tester) async {
    final fake = _Fake(null)..unreadable = true;
    await _pumpDashboard(
        tester, fake, [for (var i = 0; i < 3; i++) _nb(i, done: true)]);
    expect(find.text('Keep transcripts for…'), findsNothing);
    expect(fake.marks, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('two finished sessions, or one still live, do not offer',
      (tester) async {
    await _pumpDashboard(tester, _Fake(null), [
      _nb(0, done: true),
      _nb(1, done: true),
      _nb(2, done: false),
    ]);
    expect(find.text('Keep transcripts for…'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('privacy has one way in, and its sheet holds every setting',
      (tester) async {
    await _pumpDashboard(tester, _Fake(null, offered: true), [
      _nb(0, done: true),
    ]);
    expect(find.byKey(const Key('privacyButton')), findsOneWidget);
    expect(find.byTooltip('Privacy'), findsOneWidget);
    expect(find.byTooltip('Transcript privacy'), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsNothing);

    await tester.tap(find.byKey(const Key('privacyButton')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (final key in [
      'appLockSwitch',
      'quietModeSwitch',
      'transcriptRetentionTile',
      'exportJournalTile',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a choice goes through the setter; the current one is marked',
      (tester) async {
    final fake = _Fake(90, offered: true);
    await _pumpDashboard(tester, fake, [_nb(0, done: true)]);

    await _openRetention(tester);
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
    final fake = _Fake(30, offered: true)..failSet = true;
    await _pumpDashboard(tester, fake, [_nb(0, done: true)]);

    await _openRetention(tester);
    await tester.tap(find.byKey(const Key('retention-7')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text("Couldn't save that. Try again."), findsOneWidget);
    expect(fake.value, 30);
    await tester.pumpWidget(const SizedBox());
  });
}
