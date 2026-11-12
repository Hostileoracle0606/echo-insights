// Phase 2 (I2): a forget on one device reaches the others.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/services/forget_sync.dart';
import 'package:lumen/services/session_brief_service.dart';

import 'support/pseudonyms.dart';

class _Brief implements SessionBriefService {
  _Brief(this.brief);
  SessionBrief? brief;
  bool failLoad = false;
  int loads = 0;

  @override
  Future<SessionOpeningState> load() async {
    loads += 1;
    if (failLoad) throw StateError('offline');
    return SessionOpeningState(returning: true, brief: brief);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SessionBrief _brief() => SessionBrief(
      focus: const [],
      openingThread: '',
      openingLine: 'How is Priya Raman?',
      createdAt: DateTime.now(),
      playedAt: null,
      pcm: Uint8List(4),
      sampleRate: 24000,
    );

void main() {
  late MemoryStore store;
  late String? owner;
  late Object? marker;
  late bool failFetch;
  late int logClears;
  late int briefReloads;
  late List<Set<String>> prunes;
  late bool? trusted;
  late DateTime now;
  late ForgetSync sync;

  Object row(int count, String? latest) =>
      [
        {'forgotten_count': count, 'latest_at': latest}
      ];

  setUp(() {
    store = MemoryStore();
    owner = 'u1';
    marker = row(0, null);
    failFetch = false;
    logClears = 0;
    briefReloads = 0;
    prunes = [];
    trusted = null;
    now = DateTime.utc(2026, 11, 12, 12);
    sync = ForgetSync(
      fetch: () async {
        if (failFetch) throw StateError('offline');
        return marker;
      },
      store: store,
      ownerId: () => owner,
      clearSharedLog: () async => logClears += 1,
      reloadBrief: () async => briefReloads += 1,
      pruneNames: (live) async => prunes.add(live),
      setBriefTrusted: (ok) => trusted = ok,
      now: () => now,
    );
  });

  test('first sight of an account with nobody forgotten cleans nothing',
      () async {
    await sync.check();
    expect(logClears, 0);
    expect(briefReloads, 0);
    expect(store.saved, isNotNull, reason: 'the marker is remembered');
    expect(trusted, isTrue);
  });

  test('a forget elsewhere clears the log, the brief and the name map',
      () async {
    await sync.check();
    marker = row(1, '2026-11-12T11:00:00+00:00');
    await sync.check(liveEntityIds: {'sam'});

    expect(logClears, 1);
    expect(briefReloads, 1);
    expect(prunes, [
      {'sam'}
    ]);
    // Seen now: the same marker cleans nothing more.
    await sync.check(liveEntityIds: {'sam'});
    expect(logClears, 1);
  });

  test('the same count with a newer time still counts as a forget', () async {
    marker = row(1, '2026-11-12T11:00:00+00:00');
    await sync.check(liveEntityIds: {});
    logClears = 0;
    marker = row(1, '2026-11-12T13:00:00+00:00');
    await sync.check(liveEntityIds: {});
    expect(logClears, 1);
  });

  test('a device that never saw the marker cleans once if anyone is forgotten',
      () async {
    marker = row(2, '2026-11-10T11:00:00+00:00');
    await sync.check(liveEntityIds: {'a'});
    expect(logClears, 1);
    await sync.check(liveEntityIds: {'a'});
    expect(logClears, 1);
  });

  test('without the graph the log and brief are cleaned and the check repeats '
      'until the names are too', () async {
    await sync.check();
    marker = row(1, '2026-11-12T11:00:00+00:00');
    await sync.check();
    expect(logClears, 1);
    expect(briefReloads, 1);
    expect(prunes, isEmpty);

    await sync.check(liveEntityIds: {'sam'});
    expect(prunes, [
      {'sam'}
    ], reason: 'not marked seen until the name map was pruned');
    await sync.check(liveEntityIds: {'sam'});
    expect(prunes, hasLength(1));
  });

  test("another account's saved marker is not trusted", () async {
    marker = row(1, '2026-11-10T11:00:00+00:00');
    await sync.check(liveEntityIds: {});
    owner = 'u2';
    logClears = 0;
    await sync.check(liveEntityIds: {});
    expect(logClears, 1, reason: 'u2 has not seen it on this phone');
  });

  test('a failed check distrusts the held brief until one succeeds', () async {
    failFetch = true;
    await sync.check();
    expect(trusted, isFalse);
    failFetch = false;
    await sync.check();
    expect(trusted, isTrue);
  });

  test('nobody signed in: nothing happens', () async {
    owner = null;
    await sync.check();
    expect(store.saved, isNull);
    expect(trusted, isNull);
  });

  test('snapshot-driven checks are throttled; resume and sign-in are not',
      () async {
    await sync.check(force: true);
    marker = row(1, '2026-11-12T11:00:00+00:00');
    await sync.check(liveEntityIds: {}, force: false);
    expect(logClears, 0, reason: 'too soon');
    now = now.add(const Duration(minutes: 2));
    await sync.check(liveEntityIds: {}, force: false);
    expect(logClears, 1);
  });

  test('acknowledging this device\'s own forget stores the marker without '
      'cleaning', () async {
    marker = row(1, '2026-11-12T11:00:00+00:00');
    await sync.acknowledge();
    await sync.check(liveEntityIds: {});
    expect(logClears, 0);
  });

  group('the held brief', () {
    test('is not played while the forget check is failing', () async {
      final service = _Brief(_brief());
      final prep = OpeningPrep(service);
      await prep.refresh();
      expect(prep.current?.brief, isNotNull);
      prep.setForgetCheckOk(false);
      expect(prep.current?.brief, isNull);
      expect(prep.current?.returning, isTrue);
      prep.setForgetCheckOk(true);
      expect(prep.current?.brief, isNotNull);
    });

    test('a refresh while the check is failing does not bring it back',
        () async {
      final prep = OpeningPrep(_Brief(_brief()));
      prep.setForgetCheckOk(false);
      await prep.refresh();
      expect(prep.current?.brief, isNull);
    });

    test('sign-out resets it', () async {
      final prep = OpeningPrep(_Brief(_brief()));
      prep.setForgetCheckOk(false);
      prep.clear();
      await prep.refresh();
      expect(prep.current?.brief, isNotNull);
    });
  });

  test('it is wired at sign-in, on resume, on snapshot adopt and on a local '
      'forget', () {
    final voice =
        File('lib/providers/voice_services_provider.dart').readAsStringSync();
    expect(RegExp('runForgetCheck').allMatches(voice).length, 2,
        reason: 'warmUp and onResume');
    final journal =
        File('lib/providers/journal_provider.dart').readAsStringSync();
    expect(journal, contains('runForgetCheck('));
    expect(journal, contains('live: next.entities.keys.toSet()'));
    expect(journal, contains('forgetSyncProvider).acknowledge()'));
  });
}
