// LM-55: the name map on the device: saving, restoring, recognizer failures,
// sign-out clearing, the forget interaction and the native channel's Dart side.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/pseudonym/fake_names.dart';
import 'package:lumen/logic/pseudonym/name_recognizer.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';
import 'package:lumen/models/session_brief.dart';
import 'package:lumen/providers/opening_prep_provider.dart';
import 'package:lumen/providers/pseudonym_provider.dart';
import 'package:lumen/providers/voice_services_provider.dart';
import 'package:lumen/services/name_recognizer_channel.dart';
import 'package:lumen/services/pseudonym_service.dart';
import 'package:lumen/services/pseudonym_store.dart';
import 'package:lumen/services/session_brief_service.dart';

class MemoryPseudonymStore implements PseudonymStore {
  String? saved;
  int writes = 0;
  int deletes = 0;
  bool failReads = false;
  bool failWrites = false;
  bool failDeletes = false;

  @override
  Future<String?> read() async {
    if (failReads) throw StateError('keychain');
    return saved;
  }

  @override
  Future<void> write(String json) async {
    if (failWrites) throw StateError('keychain');
    writes++;
    saved = json;
  }

  @override
  Future<void> delete() async {
    deletes++;
    if (failDeletes) throw StateError('keychain');
    saved = null;
  }
}

class FakeRecognizer implements NameRecognizer {
  FakeRecognizer(this.names);
  List<RecognizedName> names;
  Object? error;
  Duration? delay;
  int calls = 0;

  @override
  Future<List<RecognizedName>> recognize(String text) async {
    calls++;
    if (delay != null) await Future<void>.delayed(delay!);
    if (error != null) throw error!;
    return names;
  }
}

PseudonymEntity person(String id, String name, {List<String> aliases = const []}) =>
    PseudonymEntity(id: id, name: name, kind: PseudonymKind.person, aliases: aliases);

class _NoBriefs implements SessionBriefService {
  @override
  Future<SessionOpeningState> load() async =>
      const SessionOpeningState(returning: false, brief: null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late MemoryPseudonymStore store;

  setUp(() => store = MemoryPseudonymStore());

  group('persistence', () {
    test('sync saves; the map is restored by a new service with the same fakes', () async {
      final a = PseudonymService(store: store);
      await a.sync([person('priya', 'Priya'), person('sam', 'Samantha', aliases: ['Sam'])]);
      final first = (await a.dehydrate('Priya and Sam')).text;
      expect(first, isNot(contains('Priya')));

      final b = PseudonymService(store: store);
      expect((await b.dehydrate('Priya and Sam')).text, first);
      expect(await b.rehydrate(first), 'Priya and Samantha');
    });

    test('sync with nothing new does not write again', () async {
      final s = PseudonymService(store: store);
      await s.sync([person('priya', 'Priya')]);
      final writes = store.writes;
      await s.sync([person('priya', 'Priya')]);
      expect(store.writes, writes);
    });

    test('a new name is saved before dehydrate returns', () async {
      final s = PseudonymService(
        store: store,
        recognizer: FakeRecognizer(const [RecognizedName('Teodor', PseudonymKind.person)]),
      );
      final d = await s.dehydrate('Teodor lent me a ladder.');
      expect(d.text, isNot(contains('Teodor')));
      // A restart between the call and its answer still restores the name.
      final after = PseudonymService(store: store);
      expect(await after.rehydrate(d.text), 'Teodor lent me a ladder.');
    });

    test('the same new name gets the same fake next time', () async {
      final s = PseudonymService(
        store: store,
        recognizer: FakeRecognizer(const [RecognizedName('Teodor', PseudonymKind.person)]),
      );
      final a = (await s.dehydrate('Teodor waved.')).text;
      final b = (await s.dehydrate('Then Teodor left.')).text;
      expect(b, 'Then ${a.replaceAll(' waved.', '')} left.');
    });

    test('a failed Keychain write leaves the map working in memory', () async {
      store.failWrites = true;
      final s = PseudonymService(store: store);
      await s.sync([person('priya', 'Priya')]);
      final out = (await s.dehydrate('Priya called')).text;
      expect(out, isNot(contains('Priya')));
      expect(await s.rehydrate(out), 'Priya called');
    });

    test('an unreadable or corrupt saved map starts empty and is erased', () async {
      store.saved = '{not json';
      final s = PseudonymService(store: store);
      expect((await s.dehydrate('Priya called')).text, 'Priya called');
      expect(store.saved, isNull);

      store
        ..saved = jsonEncode({'v': 9})
        ..failReads = false;
      final t = PseudonymService(store: store);
      expect((await t.dehydrate('Priya called')).text, 'Priya called');

      store.failReads = true;
      final u = PseudonymService(store: store);
      expect((await u.dehydrate('Priya called')).text, 'Priya called');
    });

    test("another account's map is discarded", () async {
      final a = PseudonymService(store: store);
      await a.load(ownerId: 'user-a');
      await a.sync([person('priya', 'Priya')]);
      expect(store.saved, contains('user-a'));

      final b = PseudonymService(store: store);
      await b.load(ownerId: 'user-b');
      expect((await b.dehydrate('Priya called')).text, 'Priya called');
      expect(store.saved, isNull);

      final c = PseudonymService(store: store);
      await c.load(ownerId: 'user-b');
      await c.sync([person('priya', 'Priya')]);
      final same = PseudonymService(store: store);
      await same.load(ownerId: 'user-b');
      expect((await same.dehydrate('Priya called')).text, isNot(contains('Priya')));
    });

    test('calls are serialised: concurrent dehydrates agree', () async {
      final s = PseudonymService(
        store: store,
        recognizer: FakeRecognizer(const [RecognizedName('Teodor', PseudonymKind.person)]),
      );
      final results = await Future.wait([
        s.dehydrate('Teodor one'),
        s.dehydrate('Teodor two'),
        s.dehydrate('Teodor three'),
      ]);
      final fakes = results.map((d) => d.text.split(' ').first).toSet();
      expect(fakes.length, 1);
    });
  });

  group('recognizer failure', () {
    test('a throwing recognizer means known-name swapping only', () async {
      final r = FakeRecognizer(const [])..error = StateError('native');
      final s = PseudonymService(store: store, recognizer: r);
      await s.sync([person('priya', 'Priya')]);
      final d = await s.dehydrate('Priya met Teodor.');
      expect(d.text, isNot(contains('Priya')));
      expect(d.text, contains('Teodor'));
      expect(r.calls, 1);
    });

    test('a missing native plugin is a failure, not a crash', () async {
      final s = PseudonymService(
        store: store,
        recognizer: NativeNameRecognizer(const MethodChannel('lumen/none')),
      );
      await s.sync([person('priya', 'Priya')]);
      final d = await s.dehydrate('Priya met Teodor.');
      expect(d.text, contains('Teodor'));
      expect(d.text, isNot(contains('Priya')));
    });

    test('a recognizer that hangs is given up on', () async {
      final r = FakeRecognizer(const [RecognizedName('Teodor', PseudonymKind.person)])
        ..delay = const Duration(seconds: 5);
      final s = PseudonymService(
        store: store,
        recognizer: r,
        recognizerTimeout: const Duration(milliseconds: 20),
      );
      expect((await s.dehydrate('Teodor waved')).text, 'Teodor waved');
    });

    test('no recognizer at all is fine', () async {
      final s = PseudonymService(store: store);
      expect((await s.dehydrate('Teodor waved')).text, 'Teodor waved');
    });
  });

  group('native channel', () {
    const channel = MethodChannel('lumen/name_recognizer');
    TestDefaultBinaryMessenger messenger() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() => TestWidgetsFlutterBinding.ensureInitialized());
    tearDown(() => messenger().setMockMethodCallHandler(channel, null));

    test('sends the text and parses person / place / org', () async {
      MethodCall? seen;
      messenger().setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return [
          {'text': 'Priya', 'kind': 'person'},
          {'text': 'Wiscasset', 'kind': 'place'},
          {'text': 'Kestrel Bioworks', 'kind': 'org'},
          {'text': 'Odd', 'kind': 'weather'},
          {'kind': 'person'},
        ];
      });
      final names = await NativeNameRecognizer().recognize('hello');
      expect(seen!.method, 'recognize');
      expect(seen!.arguments, {'text': 'hello'});
      expect(names.map((n) => (n.text, n.kind)), [
        ('Priya', PseudonymKind.person),
        ('Wiscasset', PseudonymKind.place),
        ('Kestrel Bioworks', PseudonymKind.org),
      ]);
    });

    test('a platform error reaches the caller, which treats it as no names', () async {
      messenger().setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'name_recognizer');
      });
      final s = PseudonymService(store: store, recognizer: NativeNameRecognizer());
      expect((await s.dehydrate('Teodor waved')).text, 'Teodor waved');
    });
  });

  group('sign-out', () {
    test('clear erases memory and the Keychain item', () async {
      final s = PseudonymService(store: store);
      await s.sync([person('priya', 'Priya')]);
      expect(store.saved, isNotNull);
      await s.clear();
      expect(store.saved, isNull);
      // Nothing is left in memory either.
      expect((await s.dehydrate('Priya called')).text, 'Priya called');
    });

    test('a failed delete does not throw', () async {
      final s = PseudonymService(store: store);
      await s.sync([person('priya', 'Priya')]);
      store.failDeletes = true;
      await s.clear();
    });

    test('signedOutCleanupProvider clears the name map', () async {
      final service = PseudonymService(store: store);
      await service.sync([person('priya', 'Priya')]);
      final container = ProviderContainer(overrides: [
        openingPrepProvider.overrideWithValue(OpeningPrep(_NoBriefs())),
        pseudonymServiceProvider.overrideWithValue(service),
      ]);
      addTearDown(container.dispose);

      container.read(signedOutCleanupProvider)();
      await pumpEventQueue();

      expect(store.saved, isNull);
      expect((await service.dehydrate('Priya called')).text, 'Priya called');
    });

    test('the real provider survives sign-out with no platform behind it', () async {
      final container = ProviderContainer(overrides: [
        openingPrepProvider.overrideWithValue(OpeningPrep(_NoBriefs())),
      ]);
      addTearDown(container.dispose);
      container.read(signedOutCleanupProvider)();
      await pumpEventQueue();
    });
  });

  group('forget', () {
    test('forgetting a person removes them from the stored map', () async {
      final s = PseudonymService(store: store);
      await s.sync([person('sam', 'Samantha', aliases: ['Sam']), person('priya', 'Priya')]);
      final fake = (await s.dehydrate('Samantha')).text;
      expect(store.saved, contains('Samantha'));

      await s.forget('sam');

      expect(store.saved, isNot(contains('Samantha')));
      expect(store.saved, contains('Priya'));
      expect((await s.dehydrate('Samantha')).text, 'Samantha');
      expect(await s.rehydrate(fake), fake);
    });

    test('a forgotten person is not brought back by a later sync that suppresses them', () async {
      final s = PseudonymService(store: store);
      await s.sync([person('sam', 'Samantha')]);
      await s.forget('sam');
      await s.sync([person('sam', 'Samantha')], suppressed: {'sam'});
      expect((await s.dehydrate('Samantha')).text, 'Samantha');
      expect(store.saved, isNot(contains('Samantha')));
    });

    test('forget with an unreadable store does not throw', () async {
      store.failReads = true;
      await PseudonymService(store: store).forget('sam');
    });
  });
}
