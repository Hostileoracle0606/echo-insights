// LM-55 fix round 1: leaks, collisions, strict restore, owner handling.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/pseudonym/fake_names.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';
import 'package:lumen/services/pseudonym_service.dart';
import 'package:lumen/services/pseudonym_store.dart';

PseudonymEntity person(String id, String name,
        {List<String> aliases = const [], Gender? gender}) =>
    PseudonymEntity(
        id: id, name: name, kind: PseudonymKind.person, aliases: aliases, gender: gender);
PseudonymEntity org(String id, String name) =>
    PseudonymEntity(id: id, name: name, kind: PseudonymKind.org);

PseudonymMap mapOf(Iterable<PseudonymEntity> e) => PseudonymMap()..sync(e);
String fakeFor(PseudonymMap m, String real) => m.dehydrate(real).text;

class MemStore implements PseudonymStore {
  String? saved;
  bool failDeletes = false;
  @override
  Future<String?> read() async => saved;
  @override
  Future<void> write(String json) async => saved = json;
  @override
  Future<void> delete() async {
    if (failDeletes) throw StateError('keychain');
    saved = null;
  }
}

void main() {
  group('partial names (critical)', () {
    test('only "Priya Raman" in the graph: the last name alone is swapped', () {
      final m = mapOf([person('p', 'Priya Raman')]);
      final fake = fakeFor(m, 'Priya Raman').split(' ').first;
      expect(m.dehydrate('Raman called.').text, '$fake called.');
      expect(m.dehydrate('Priya called.').text, '$fake called.');
      expect(m.dehydrate('Priya Raman called.').text, isNot(contains('Raman')));
    });

    test('only "Halvorsen Group": the first word alone is swapped', () {
      final m = mapOf([org('h', 'Halvorsen Group')]);
      final out = m.dehydrate('Halvorsen laid me off.').text;
      expect(out, isNot(contains('Halvorsen')));
      expect(fakeFor(m, 'Halvorsen Group'), startsWith(out.replaceAll(' laid me off.', '')));
    });

    test('three-word person: first and last word', () {
      final m = mapOf([person('a', 'Anna Maria Lopez')]);
      expect(m.dehydrate('Anna came. Lopez left.').text, isNot(contains(RegExp('Anna|Lopez'))));
    });

    test('common words are not made aliases', () {
      final m = mapOf([person('m', 'Mark Hill'), org('g', 'Garden Group')]);
      expect(m.dehydrate('The hill is steep. Hill Street. Garden party.').text,
          'The hill is steep. Hill Street. Garden party.');
    });

    test('derived aliases survive a restart', () {
      final m = mapOf([person('p', 'Priya Raman')]);
      final copy = PseudonymMap.fromJson(
          jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      expect(copy.dehydrate('Raman called').text, m.dehydrate('Raman called').text);
    });

    test('a derived alias never steals a name another entity owns', () {
      final m = mapOf([
        person('a', 'Priya Raman'),
        person('b', 'Priya Shah'),
        person('c', 'Shah'),
      ]);
      expect(fakeFor(m, 'Raman'), fakeFor(m, 'Priya Raman').split(' ').first);
      expect(fakeFor(m, 'Shah'), fakeFor(m, 'Shah'));
      expect(fakeFor(m, 'Shah'), isNot(fakeFor(m, 'Raman')));
    });
  });

  group('other leaks', () {
    test('hyphenated name written with a space', () {
      final m = mapOf([person('j', 'Jean-Luc')]);
      final out = m.dehydrate('Jean Luc said hi').text;
      expect(out, isNot(contains(RegExp('Jean|Luc'))));
      expect(m.dehydrate('Jean-Luc said hi').text, out);
    });

    test('spaced name written with a hyphen', () {
      final m = mapOf([org('h', 'Halvorsen Group')]);
      final out = m.dehydrate('I work at Halvorsen-Group.').text;
      expect(out, isNot(contains('Halvorsen')));
      expect(out, isNot(contains('Group')));
    });

    test('all-caps word-names follow the same context rules', () {
      final m = mapOf([person('w', 'Will', gender: Gender.male)]);
      final fake = fakeFor(m, 'Will');
      expect(m.dehydrate('WILL called').text, '$fake called');
      expect(m.dehydrate('WILL YOU REMIND ME').text, 'WILL YOU REMIND ME');
      expect(m.dehydrate('I WILL CALL').text, 'I WILL CALL');
      expect(m.dehydrate('will called').text, 'will called');
    });

    test('decomposed accents leave no stray mark', () {
      final m = mapOf([person('j', 'José')]);
      final fake = fakeFor(m, 'José');
      final out = m.dehydrate('José called').text;
      expect(out, '$fake called');
      expect(m.dehydrate('José called').restore(), 'José called');
      final plain = mapOf([person('j', 'Jose')]);
      expect(plain.dehydrate('José called').text, isNot(contains('́')));
    });
  });

  group('collisions', () {
    test('a real name equal to an issued fake gets that fake reissued (across a restart)', () {
      final a = mapOf([person('marcus', 'Marcus', gender: Gender.female)]);
      final old = fakeFor(a, 'Marcus');
      final restarted = PseudonymMap.fromJson(
          jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
      restarted.sync([person('marcus', 'Marcus', gender: Gender.female), person('real', old)]);
      final marcus = fakeFor(restarted, 'Marcus');
      expect(marcus, isNot(old));
      expect(restarted.rehydrateModelOutput(marcus), 'Marcus');
      // The real person with that name keeps a fake of her own.
      expect(fakeFor(restarted, old), isNot(old));
      expect(fakeFor(restarted, old), isNot(marcus));
      // The old stand-in is retired: it does not map back to Marcus.
      expect(restarted.rehydrateModelOutput(old), old);
    });

    test('reservations are persisted', () {
      final a = PseudonymMap()..sync([], allNames: [fakeFemaleNames.first]);
      final b = PseudonymMap.fromJson(
          jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>);
      b.sync([person('x', 'Xavier', gender: Gender.female)]);
      expect(fakeFor(b, 'Xavier'), isNot(fakeFemaleNames.first));
    });

    test('a name learned later that equals a fake reissues that fake', () {
      final m = mapOf([person('marcus', 'Marcus', gender: Gender.female)]);
      final old = fakeFor(m, 'Marcus');
      final d = m.dehydrate('Marcus met $old.');
      expect(d.mapChanged, isTrue);
      final parts = d.text.split(' met ');
      expect(parts[0], isNot(old));
      expect(parts[1], isNot(contains(old)));
      expect(parts[0], isNot(parts[1].replaceAll('.', '')));
      expect(d.restore(), 'Marcus met $old.');
    });
  });

  group('restore and model output', () {
    test('restore is only valid for the identical text', () {
      final m = mapOf([person('p', 'Priya')]);
      final d = m.dehydrate('Priya came');
      expect(d.restore(d.text), 'Priya came');
      expect(d.restore('>> ${d.text}'), isNull);
      expect(d.restore('${d.text}!'), isNull);
      expect(d.restore(d.text.replaceAll('came', 'went')), isNull);
    });

    test('model output returns the spelling the user used, when unambiguous', () {
      final m = mapOf([person('s', 'Samantha', aliases: ['Sam'])]);
      final fake = fakeFor(m, 'Samantha');
      m.sync(const []); // a new call cycle: forget the spellings just probed
      m.dehydrate('Sam called me.');
      expect(m.rehydrateModelOutput('$fake is kind.'), 'Sam is kind.');
      m.dehydrate('Samantha called.');
      expect(m.rehydrateModelOutput('$fake is kind.'), 'Samantha is kind.');
      expect(m.rehydrateJson({'n': fake}), {'n': 'Samantha'});
    });

    test('Pria is Priya when nothing else is closer', () {
      final m = mapOf([person('a', 'Priya')]);
      expect(m.dehydrate('Pria came').text, '${fakeFor(m, 'Priya')} came');
    });

    test('Pria and Priya as two different people stay two people', () {
      final m = mapOf([person('a', 'Priya'), person('b', 'Pria')]);
      final priya = fakeFor(m, 'Priya');
      final pria = fakeFor(m, 'Pria');
      expect(priya, isNot(pria));
      expect(m.dehydrate('Pria met Priya').text, '$pria met $priya');
      expect(m.rehydrateModelOutput('$pria met $priya'), 'Pria met Priya');
    });

    test('a fuzzy match equidistant from two people is not assigned to either', () {
      final m = mapOf([person('a', 'Priya'), person('b', 'Priyo')]);
      expect(m.dehydrate('Priyu came').text, 'Priyu came');
    });

    test('a hyphen after a stand-in is not a match', () {
      final m = mapOf([person('p', 'Priya')]);
      final fake = fakeFor(m, 'Priya');
      expect(m.rehydrateModelOutput('$fake-Rose'), '$fake-Rose');
      expect(m.rehydrateModelOutput('Rose-$fake'), 'Rose-$fake');
      expect(m.rehydrateModelOutput('$fake Rose'), 'Priya Rose');
    });
  });

  group('service owner handling', () {
    PseudonymService svc(MemStore s, String? owner) =>
        PseudonymService(store: s, ownerId: () => owner);

    test('without an owner nothing is read, deleted or written', () async {
      final s = MemStore();
      final a = svc(s, 'u1');
      await a.sync([person('p', 'Priya')]);
      final saved = s.saved;
      final anon = svc(s, null);
      expect((await anon.dehydrate('Priya called')).text, 'Priya called');
      await anon.sync([person('q', 'Quentin')]);
      await anon.forget('p');
      expect(s.saved, saved);
    });

    test("another account's map is discarded", () async {
      final s = MemStore();
      await svc(s, 'u1').sync([person('p', 'Priya')]);
      expect((await svc(s, 'u2').dehydrate('Priya called')).text, 'Priya called');
      expect(s.saved, isNull);
    });

    test('a failed Keychain delete at sign-out cannot expose the map to the next account', () async {
      final s = MemStore();
      String? owner = 'u1';
      final a = PseudonymService(store: s, ownerId: () => owner);
      await a.sync([person('p', 'Priya')]);
      s.failDeletes = true;
      await a.clear();
      expect(s.saved, isNotNull, reason: 'the delete failed');
      owner = 'u2';
      // Same process, then a fresh one: both start empty for u2.
      expect((await a.dehydrate('Priya called')).text, 'Priya called');
      expect((await svc(s, 'u2').dehydrate('Priya called')).text, 'Priya called');
      s.failDeletes = false;
      expect((await svc(s, 'u2').dehydrate('Priya called')).text, 'Priya called');
      expect(s.saved, isNull);
    });

    test('clear is serial with the calls around it', () async {
      final s = MemStore();
      final a = svc(s, 'u1');
      await a.sync([person('p', 'Priya')]);
      final futures = [a.clear(), a.dehydrate('Priya called')];
      final results = await Future.wait(futures);
      expect((results[1] as Dehydrated).text, 'Priya called');
    });
  });
}
