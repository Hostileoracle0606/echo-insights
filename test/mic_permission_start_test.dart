// Microphone permission is checked before a live-session token is minted:
// every denial path makes zero requests to the runtime's live-sessions route,
// and a permanent denial raises the persistent micBlocked state, which clears
// once Settings grants access.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/providers/journal_provider.dart';
import 'package:lumen/providers/supabase_provider.dart';
import 'package:lumen/services/mic_permission_service.dart';
import 'package:lumen/services/notebook_commit_service.dart';
import 'package:lumen/services/notebook_runtime_service.dart';
import 'package:lumen/services/supabase_service.dart';
import 'package:lumen/services/turn_journal_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient _client() => SupabaseClient(
      'https://example.supabase.co',
      'anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );

class _EmptyNotebook extends NotebookCommitService {
  _EmptyNotebook() : super(_client());

  @override
  Future<NotebookSnapshot?> getNotebookSnapshot(String notebookId) async =>
      null;
}

class _FakePermission implements MicPermissionService {
  _FakePermission(this.onRequest, {this.beforeRequest});
  MicPermission onRequest;
  MicPermission onStatus = MicPermission.permanentlyDenied;
  final void Function()? beforeRequest;
  int requests = 0;

  @override
  Future<MicPermission> request() async {
    requests++;
    beforeRequest?.call();
    return onRequest;
  }

  @override
  Future<MicPermission> status() async => onStatus;

  @override
  Future<bool> openSettings() async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late List<http.Request> mints;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('lumen-mic-permission-');
    mints = [];
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<(ProviderContainer, JournalNotifier)> start(
    _FakePermission permission,
  ) async {
    final container = ProviderContainer(overrides: [
      supabaseServiceProvider.overrideWithValue(SupabaseService(_client())),
      notebookCommitServiceProvider.overrideWithValue(_EmptyNotebook()),
      turnJournalServiceProvider.overrideWithValue(
        TurnJournalService(directoryProvider: () async => directory),
      ),
      notebookRuntimeServiceProvider.overrideWithValue(
        NotebookRuntimeService(
          baseUrl: 'https://runtime.example.com',
          accessTokenProvider: () async => 'user-jwt',
          client: MockClient((request) async {
            mints.add(request);
            // Stop the start right after the mint: no socket in unit tests.
            return http.Response(
              jsonEncode({'status': 'rejected', 'code': 'providerUnavailable'}),
              503,
            );
          }),
        ),
      ),
      micPermissionServiceProvider.overrideWithValue(permission),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(journalProvider.notifier);
    expect((await notifier.enterNotebook('notebook-1')).succeeded, isTrue);
    return (container, notifier);
  }

  test('permanent denial mints no token and raises micBlocked', () async {
    final permission = _FakePermission(MicPermission.permanentlyDenied);
    final (_, notifier) = await start(permission);

    final result = await notifier.startSession();

    expect(result.succeeded, isFalse);
    expect(permission.requests, 1);
    expect(mints, isEmpty);
    expect(notifier.micBlocked, isTrue);
    expect(notifier.status, SessionStatus.error);
  });

  test('a dismissible denial mints no token and is not blocked', () async {
    final permission = _FakePermission(MicPermission.denied);
    final (_, notifier) = await start(permission);

    final result = await notifier.startSession();

    expect(result.succeeded, isFalse);
    expect(mints, isEmpty);
    expect(notifier.micBlocked, isFalse);
  });

  test('a granted microphone proceeds to mint exactly one token', () async {
    int? mintsWhenAsked;
    final permission = _FakePermission(
      MicPermission.granted,
      beforeRequest: () => mintsWhenAsked = mints.length,
    );
    final (_, notifier) = await start(permission);

    await notifier.startSession();

    expect(mintsWhenAsked, 0, reason: 'permission is asked before minting');
    expect(mints, hasLength(1));
    expect(mints.single.url.path,
        '/v1/notebooks/notebook-1/live-sessions');
    expect(notifier.micBlocked, isFalse);
  });

  test('returning from Settings with access granted clears micBlocked',
      () async {
    final permission = _FakePermission(MicPermission.permanentlyDenied);
    final (_, notifier) = await start(permission);
    await notifier.startSession();
    expect(notifier.micBlocked, isTrue);

    permission.onStatus = MicPermission.granted;
    notifier.handleAppLifecycle(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);

    expect(notifier.micBlocked, isFalse);
  });
}
