// LM-30: the graph drawer's "Export notebook" action builds the open
// notebook's vault, shows progress while it works, and hands the vault to the
// share function. The share function is injected through shareVaultProvider,
// so the real iOS share sheet never opens here.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/journal_state.dart';
import 'package:lumen/providers/export_provider.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/screens/journal/graph_drawer.dart';
import 'package:lumen/services/markdown_export.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _SeededJournal extends JournalNotifier {
  _SeededJournal(this._seed);
  final JournalState _seed;
  @override
  JournalState build() => _seed;
}

JournalState _seedState() {
  final now = DateTime.utc(2026, 4, 26, 14);
  return JournalState(
    entries: const [],
    entities: {
      'maya': Entity(
        id: 'maya',
        name: 'Maya',
        type: EntityType.person,
        metadata: const {},
        mentions: 2,
        firstSeen: now,
        lastSeen: now,
      ),
    },
    relations: const {},
    followUps: const [],
  );
}

Future<void> _pumpDrawer(WidgetTester tester, ShareVault share) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        journalProvider.overrideWith(() => _SeededJournal(_seedState())),
        shareVaultProvider.overrideWithValue(share),
      ],
      child: MaterialApp(
        theme: LumenTheme.light(),
        home: Scaffold(body: GraphDrawer(onEntityTap: (_) {})),
      ),
    ),
  );
}

final _exportButton = find.widgetWithText(TextButton, 'Export notebook');

void main() {
  testWidgets('Export shows progress, then shares the notebook vault',
      (tester) async {
    final shared = <MarkdownVault>[];
    final done = Completer<void>();
    await _pumpDrawer(tester, (vault, {Rect? origin}) {
      shared.add(vault);
      return done.future;
    });

    expect(_exportButton, findsOneWidget);
    expect(tester.getSize(_exportButton).height, greaterThanOrEqualTo(44));

    await tester.tap(_exportButton);
    await tester.pump();
    await tester.pump();

    expect(find.text('Building export…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(shared, hasLength(1));
    expect(shared.single.files.keys, contains('Lumen Vault/Maya.md'));

    done.complete();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(_exportButton, findsOneWidget);
  });

  testWidgets('a failed export says so and can be retried', (tester) async {
    var calls = 0;
    await _pumpDrawer(tester, (vault, {Rect? origin}) async {
      calls++;
      throw StateError('disk full');
    });

    await tester.tap(_exportButton);
    await tester.pump();
    await tester.pump();

    expect(find.text("Couldn't build the export. Try again."), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(_exportButton);
    await tester.pump();
    await tester.pump();
    expect(calls, 2);
  });
}
