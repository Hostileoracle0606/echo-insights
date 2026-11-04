// LM-52: the privacy sheet's "Export my journal" asks for Face ID first,
// shows progress, shares the zip through shareVaultProvider (so the real iOS
// share sheet never opens here) and shows a plain error that carries no
// journal content.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/export_provider.dart';
import 'package:lumen/screens/dashboard/privacy_sheet.dart';
import 'package:lumen/security/app_lock.dart';
import 'package:lumen/security/app_lock_provider.dart';
import 'package:lumen/services/journal_export_service.dart';
import 'package:lumen/services/markdown_export.dart';
import 'package:lumen/theme/lumen_theme.dart';

class _Auth implements LockAuthenticator {
  _Auth(this.passes);
  final bool passes;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<bool> authenticate(String reason) async => passes;
}

final _fixture = jsonDecode(
        File('test/fixtures/journal_export/export.json').readAsStringSync())
    as Map<String, dynamic>;

Future<void> _pump(
  WidgetTester tester, {
  required ShareVault share,
  bool authPasses = true,
  required Future<dynamic> Function(String, Map<String, dynamic>) rpc,
}) async {
  await tester.binding.setSurfaceSize(const Size(402, 874));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        shareVaultProvider.overrideWithValue(share),
        lockAuthenticatorProvider.overrideWithValue(_Auth(authPasses)),
        journalExportServiceProvider.overrideWithValue(
          JournalExportService(
            rpc: rpc,
            listNotebookIds: () async =>
                ['a1111111-0000-0000-0000-000000000001'],
          ),
        ),
      ],
      child: MaterialApp(
        theme: LumenTheme.light(),
        home: const Scaffold(body: PrivacySheet()),
      ),
    ),
  );
  await tester.pump();
}

final _tile = find.byKey(const Key('exportJournalTile'));

void main() {
  testWidgets('a failed re-auth fetches and shares nothing', (tester) async {
    var rpcCalls = 0;
    var shared = 0;
    await _pump(
      tester,
      authPasses: false,
      share: (vault, {Rect? origin}) async => shared++,
      rpc: (fn, params) async {
        rpcCalls++;
        return _fixture;
      },
    );
    await tester.tap(_tile);
    await tester.pumpAndSettle();
    expect(rpcCalls, 0);
    expect(shared, 0);
  });

  testWidgets('shows progress, then shares the zip contents', (tester) async {
    final shared = <MarkdownVault>[];
    final release = Completer<void>();
    await _pump(
      tester,
      share: (vault, {Rect? origin}) {
        shared.add(vault);
        return release.future;
      },
      rpc: (fn, params) async => _fixture,
    );

    await tester.runAsync(() async {
      await tester.tap(_tile);
      // Let the RPC, the isolate build and the share call run.
      for (var i = 0; i < 50 && shared.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    expect(shared, hasLength(1));
    expect(shared.single.files.keys.first, 'lumen-journal.json');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    release.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Export my journal'), findsOneWidget);
  });

  testWidgets('a failure shows a plain message with no content',
      (tester) async {
    await _pump(
      tester,
      share: (vault, {Rect? origin}) async {},
      rpc: (fn, params) async => throw StateError('my private journal words'),
    );
    await tester.tap(_tile);
    await tester.pumpAndSettle();

    expect(find.textContaining('did not finish'), findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
