// Phase 2 (I2): a forget on one device reaches the others.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:lumen/audio/audio_output.dart';
import 'package:lumen/logic/opening_choice.dart';
import 'package:lumen/logic/pseudonym/fake_names.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/live_credentials.dart';
import 'package:lumen/services/pseudonym_service.dart';
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
  late Set<String> accountIds;
  late bool failAccountIds;
  late bool? trusted;
  late DateTime now;
  late ForgetSync sync;

  Object row(int count, String? latest) => [
        {'forgotten_count': count, 'latest_at': latest}
      ];

  ForgetSync make({Future<Object?> Function()? fetch}) => ForgetSync(
        fetch: fetch ??
            () async {
              if (failFetch) throw StateError('offline');
              return marker;
            },
        store: store,
        ownerId: () => owner,
        clearSharedLog: () async => logClears += 1,
        reloadBrief: () async => briefReloads += 1,
        accountEntityIds: () async {
          if (failAccountIds) throw StateError('offline');
          return accountIds;
        },
        pruneNames: (ids) async => prunes.add(ids),
        setBriefTrusted: (ok) => trusted = ok,
        now: () => now,
      );

  setUp(() {
    store = MemoryStore();
    owner = 'u1';
    marker = row(0, null);
    failFetch = false;
    logClears = 0;
    briefReloads = 0;
    prunes = [];
    accountIds = {'sam', 'priya'};
    failAccountIds = false;
    trusted = null;
    now = DateTime.utc(2026, 11, 12, 12);
    sync = make();
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
    await sync.check();

    expect(logClears, 1);
    expect(briefReloads, 1);
    expect(prunes, [accountIds]);
    await sync.check();
    expect(logClears, 1, reason: 'handled');
  });

  test('the same count with a newer time still counts as a forget', () async {
    marker = row(1, '2026-11-12T11:00:00+00:00');
    await sync.check();
    logClears = 0;
    marker = row(1, '2026-11-12T13:00:00+00:00');
    await sync.check();
    expect(logClears, 1);
  });

  test('a device that never saw the marker cleans once if anyone is forgotten',
      () async {
    marker = row(2, '2026-11-10T11:00:00+00:00');
    await sync.check();
    expect(logClears, 1);
    await sync.check();
    expect(logClears, 1);
  });

  test("another account's saved marker is not trusted", () async {
    marker = row(1, '2026-11-10T11:00:00+00:00');
    await sync.check();
    owner = 'u2';
    logClears = 0;
    await sync.check();
    expect(logClears, 1, reason: 'u2 has not seen it on this phone');
  });

  test('nobody signed in: nothing happens', () async {
    owner = null;
    await sync.check();
    expect(store.saved, isNull);
    expect(logClears, 0);
  });

  group('the held brief (fails closed)', () {
    test('a failed check distrusts it until one succeeds', () async {
      failFetch = true;
      await sync.check();
      expect(trusted, isFalse);
      failFetch = false;
      await sync.check();
      expect(trusted, isTrue);
    });

    test('is distrusted from the moment a forced check starts, before the '
        'marker call returns', () async {
      final gate = Completer<Object?>();
      final slow = make(fetch: () => gate.future);
      final prep = OpeningPrep(_Brief(_brief()));
      await prep.refresh();
      final gated = ForgetSync(
        fetch: () => gate.future,
        store: store,
        ownerId: () => owner,
        clearSharedLog: () async {},
        reloadBrief: () async {},
        setBriefTrusted: prep.setForgetCheckOk,
        now: () => now,
      );
      expect(slow, isNotNull);

      final running = gated.check();
      // A session starts now: the opening choice reads the held state.
      expect(prep.current?.brief, isNull);
      final choice = chooseOpening(
        state: prep.current,
        knownNewAccount: false,
        now: DateTime.now(),
      );
      expect(choice, OpeningChoice.fallback, reason: 'no brief audio');

      gate.complete(row(0, null));
      await running;
      expect(prep.current?.brief, isNotNull);
    });

    test('a check that is not forced (a snapshot adopt) does not distrust it',
        () async {
      await sync.check();
      trusted = null;
      now = now.add(const Duration(minutes: 5));
      final f = sync.check(force: false);
      expect(trusted, isNull);
      await f;
    });

    test('going to the background distrusts it until the next check', () async {
      var backgrounds = 0;
      final binding = VoiceServicesBinding(
        credentials: LiveCredentials(fetch: () async => throw StateError('x')),
        audioOutput: AudioOutput(),
        runtimeConfigured: false,
        onBackground: () => backgrounds += 1,
      );
      binding.lifecycleChanged(AppLifecycleState.paused);
      expect(backgrounds, 0, reason: 'ignored while signed out');
      binding.signedInChanged(true);
      binding.lifecycleChanged(AppLifecycleState.paused);
      binding.lifecycleChanged(AppLifecycleState.hidden);
      expect(backgrounds, 2);
      binding.lifecycleChanged(AppLifecycleState.inactive);
      expect(backgrounds, 2);
      binding.signedInChanged(false);
    });

    test('is not played while the check is failing', () async {
      final prep = OpeningPrep(_Brief(_brief()));
      await prep.refresh();
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

  group('the name map is pruned against the whole account', () {
    PseudonymEntity person(String id, String name) => PseudonymEntity(
        id: id, name: name, kind: PseudonymKind.person, aliases: const []);

    test('people in other notebooks stay in the map and stay swapped',
        () async {
      final mapStore = MemoryStore();
      final names = PseudonymService(ownerId: () => 'u1', store: mapStore);
      await names.sync([
        person('priya', 'Priya'),
        person('sam', 'Samantha'),
        person('gone', 'Gordon'),
      ]);
      final swappedBefore = (await names.dehydrate('Priya and Samantha')).text;

      final real = ForgetSync(
        fetch: () async => marker,
        store: store,
        ownerId: () => owner,
        clearSharedLog: () async {},
        reloadBrief: () async {},
        // Priya and Sam are in other notebooks; only Gordon is gone.
        accountEntityIds: () async => {'priya', 'sam'},
        pruneNames: names.pruneTo,
        setBriefTrusted: (_) {},
        now: () => now,
      );
      await real.check();
      marker = row(1, '2026-11-12T11:00:00+00:00');
      await real.check();

      expect(mapStore.saved, contains('Priya'));
      expect(mapStore.saved, contains('Samantha'));
      expect(mapStore.saved, isNot(contains('Gordon')));
      expect((await names.dehydrate('Priya and Samantha')).text, swappedBefore);
      expect((await names.dehydrate('Gordon called')).text, 'Gordon called');
    });

    test('the graph of one open notebook is never what is pruned against', () {
      final journal =
          File('lib/providers/journal_provider.dart').readAsStringSync();
      expect(journal, isNot(contains('live: next.entities')));
      final provider =
          File('lib/providers/forget_sync_provider.dart').readAsStringSync();
      expect(provider, contains("'user_entities'"));
    });

    test('if the account list can not be read nothing is pruned and the '
        'marker stays unseen; log and brief are not wiped twice', () async {
      await sync.check();
      marker = row(1, '2026-11-12T11:00:00+00:00');
      failAccountIds = true;
      await sync.check();
      expect(prunes, isEmpty);
      expect(logClears, 1);
      expect(briefReloads, 1);

      failAccountIds = false;
      await sync.check();
      expect(prunes, [accountIds]);
      expect(logClears, 1, reason: 'a resume does not wipe the log again');
      expect(briefReloads, 1);
      await sync.check();
      expect(prunes, hasLength(1), reason: 'now seen');
    });

    test('a deferred prune does not throttle the next snapshot check',
        () async {
      await sync.check();
      marker = row(1, '2026-11-12T11:00:00+00:00');
      failAccountIds = true;
      await sync.check();
      failAccountIds = false;
      // Within the throttle gap, but the last check did not finish its job.
      await sync.check(force: false);
      expect(prunes, [accountIds]);
    });
  });

  test('snapshot-driven checks are throttled; resume and sign-in are not',
      () async {
    await sync.check(force: true);
    marker = row(1, '2026-11-12T11:00:00+00:00');
    await sync.check(force: false);
    expect(logClears, 0, reason: 'too soon');
    now = now.add(const Duration(minutes: 2));
    await sync.check(force: false);
    expect(logClears, 1);
  });

  group('acknowledging this device\'s own forget', () {
    test('absorbs exactly one more forgotten person, nothing else', () async {
      marker = row(1, '2026-11-10T11:00:00+00:00');
      await sync.check();
      logClears = 0;
      marker = row(2, '2026-11-12T11:00:00+00:00');
      await sync.acknowledge();
      await sync.check();
      expect(logClears, 0, reason: 'our own forget, already cleaned');
    });

    test("another device's forget at the same time still triggers the prune",
        () async {
      marker = row(1, '2026-11-10T11:00:00+00:00');
      await sync.check();
      logClears = 0;
      marker = row(3, '2026-11-12T11:00:00+00:00');
      await sync.acknowledge();
      await sync.check();
      expect(logClears, 1);
      expect(prunes, isNotEmpty);
    });

    test('a device that has not seen the marker acknowledges nothing',
        () async {
      marker = row(2, '2026-11-12T11:00:00+00:00');
      await sync.acknowledge();
      await sync.check();
      expect(logClears, 1);
    });
  });

  test('it is wired at sign-in, on resume, on snapshot adopt, on background '
      'and on a local forget', () {
    final voice =
        File('lib/providers/voice_services_provider.dart').readAsStringSync();
    expect(RegExp('runForgetCheck').allMatches(voice).length, 2,
        reason: 'warmUp and onResume');
    expect(voice, contains('onBackground'));
    final journal =
        File('lib/providers/journal_provider.dart').readAsStringSync();
    expect(journal, contains('runForgetCheck('));
    expect(journal, contains('forgetSyncProvider).acknowledge()'));
  });
}
