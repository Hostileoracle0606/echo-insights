// LM-55: the on-device name swap. Pure logic; no platform.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/pseudonym/common_words.dart';
import 'package:lumen/logic/pseudonym/fake_names.dart';
import 'package:lumen/logic/pseudonym/name_recognizer.dart';
import 'package:lumen/logic/pseudonym/public_entities.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';
import 'package:lumen/models/entity.dart';

PseudonymEntity person(
  String id,
  String name, {
  List<String> aliases = const [],
  Gender? gender,
}) =>
    PseudonymEntity(
      id: id,
      name: name,
      kind: PseudonymKind.person,
      aliases: aliases,
      gender: gender,
    );

PseudonymEntity place(String id, String name) =>
    PseudonymEntity(id: id, name: name, kind: PseudonymKind.place);

PseudonymEntity org(String id, String name, {List<String> aliases = const []}) =>
    PseudonymEntity(
      id: id,
      name: name,
      kind: PseudonymKind.org,
      aliases: aliases,
    );

PseudonymMap mapOf(Iterable<PseudonymEntity> entities) =>
    PseudonymMap()..sync(entities);

/// The stand-in the map issued for [real] when it appears alone.
String fakeFor(PseudonymMap map, String real) => map.dehydrate(real).text;

void main() {
  group('consistent fake names', () {
    test('the same real name always gets the same fake name', () {
      final map = mapOf([person('priya', 'Priya')]);
      final a = fakeFor(map, 'Priya');
      expect(a, isNot('Priya'));
      expect(fakeFor(map, 'Priya'), a);
      expect(map.dehydrate('I saw Priya. Priya laughed.').text,
          'I saw $a. $a laughed.');
    });

    test('different people get different fakes', () {
      final map = mapOf([
        person('priya', 'Priya'),
        person('maya', 'Maya'),
        person('anna', 'Anna'),
      ]);
      final fakes = {
        fakeFor(map, 'Priya'),
        fakeFor(map, 'Maya'),
        fakeFor(map, 'Anna'),
      };
      expect(fakes.length, 3);
    });

    test('a person gets a person name, a place a place, an org an org', () {
      final map = mapOf([
        person('priya', 'Priya'),
        place('gardiner', 'Gardiner'),
        org('halvorsen', 'Halvorsen Marine Instruments'),
      ]);
      expect([...fakeFemaleNames, ...fakeMaleNames, ...fakeNeutralNames],
          contains(fakeFor(map, 'Priya')));
      expect(fakePlaceNames, contains(fakeFor(map, 'Gardiner')));
      expect(fakeOrgNames, contains(fakeFor(map, 'Halvorsen Marine Instruments')));
    });

    test('gender follows a role or the name where one is known', () {
      final f = mapOf([person('a', 'Dana', gender: Gender.female)]);
      final m = mapOf([person('b', 'Dana', gender: Gender.male)]);
      expect(
        [...fakeFemaleNames, ...fakeNeutralNames],
        contains(fakeFor(f, 'Dana')),
      );
      expect(
        [...fakeMaleNames, ...fakeNeutralNames],
        contains(fakeFor(m, 'Dana')),
      );
    });

    test('gender comes from the graph entity: role words, pronouns, names', () {
      Entity entity(String name, {String? description, Map<String, dynamic>? metadata}) =>
          Entity(
            id: name.toLowerCase(),
            name: name,
            type: EntityType.person,
            description: description,
            metadata: metadata ?? {},
            mentions: 1,
            firstSeen: DateTime(2026),
            lastSeen: DateTime(2026),
          );
      expect(
        PseudonymEntity.fromEntity(entity('Jo', description: 'The user\'s older sister.'))!.gender,
        Gender.female,
      );
      expect(
        PseudonymEntity.fromEntity(entity('Jo', description: 'He is my manager.'))!.gender,
        Gender.male,
      );
      expect(PseudonymEntity.fromEntity(entity('Priya'))!.gender, Gender.female);
      expect(PseudonymEntity.fromEntity(entity('Zed'))!.gender, isNull);
      expect(
        PseudonymEntity.fromEntity(entity('Zed', metadata: {'gender': 'female'}))!.gender,
        Gender.female,
      );
    });

    test('a fake is never a real name in the graph, nor a common word', () {
      // Real names that are in the fake pool: the fakes must route around them.
      final real = [
        for (final n in fakeFemaleNames.take(10)) person(n.toLowerCase(), n),
      ];
      final map = PseudonymMap()
        ..sync(real, allNames: ['Nora', 'Greta', 'Brightwater Optics'])
        ..sync([person('new', 'Zoltan', gender: Gender.female)]);
      final fake = fakeFor(map, 'Zoltan');
      expect(fakeFemaleNames.take(10).map((n) => n.toLowerCase()), isNot(contains(fake.toLowerCase())));
      expect(commonWords, isNot(contains(fake.toLowerCase())));
    });

    test('the bundled pools hold no common words and no duplicates', () {
      for (final n in [
        ...fakeFemaleNames,
        ...fakeMaleNames,
        ...fakeNeutralNames,
        ...fakeSurnames,
        ...fakePlaceNames,
      ]) {
        expect(commonWords, isNot(contains(n.toLowerCase())), reason: n);
      }
      for (final o in fakeOrgNames) {
        expect(isPlausibleFake(o, PseudonymKind.org), isTrue, reason: o);
      }
      final all = [
        ...fakeFemaleNames,
        ...fakeMaleNames,
        ...fakeNeutralNames,
        ...fakePlaceNames,
        ...fakeOrgNames,
      ];
      expect(all.toSet().length, all.length);
    });

    test('a new name gets a new, unused fake, even past the pool', () {
      final map = PseudonymMap();
      final entities = [
        for (var i = 0; i < 150; i++) person('p$i', 'Realname${String.fromCharCode(97 + i % 26)}${String.fromCharCode(97 + i ~/ 26)}'),
      ];
      map.sync(entities);
      final seen = <String>{};
      for (final e in entities) {
        expect(seen.add(fakeFor(map, e.name)), isTrue);
      }
    });
  });

  group('exact matching and aliases', () {
    test('aliases map to the same person', () {
      final map = mapOf([
        person('samantha', 'Samantha', aliases: ['Sam', 'Sammy'], gender: Gender.female),
      ]);
      final out = map.dehydrate('Samantha, or Sam, or Sammy.').text;
      final fake = fakeFor(map, 'Samantha');
      expect(out, '$fake, or $fake, or $fake.');
    });

    test('an alias that adds a surname gets the fake first name plus a surname', () {
      final map = mapOf([person('priya', 'Priya', aliases: ['Priya Raman'])]);
      final first = fakeFor(map, 'Priya');
      final full = fakeFor(map, 'Priya Raman');
      expect(full, startsWith('$first '));
      expect(full.split(' ').length, 2);
    });

    test('a multi-word name and its first-word alias line up', () {
      final map = mapOf([
        org('halvorsen', 'Halvorsen Marine Instruments', aliases: ['Halvorsen']),
      ]);
      final full = fakeFor(map, 'Halvorsen Marine Instruments');
      final short = fakeFor(map, 'Halvorsen');
      expect(full, startsWith(short));
      expect(map.dehydrate('I work at Halvorsen Marine Instruments.').text, 'I work at $full.');
    });

    test('relational aliases ("my sister") are not names to swap', () {
      final map = mapOf([person('s', 'Samantha', aliases: ['my sister'])]);
      expect(map.dehydrate('My sister called.').text, 'My sister called.');
    });

    test('matching ignores case and respects word boundaries', () {
      final map = mapOf([person('priya', 'Priya')]);
      final fake = fakeFor(map, 'Priya');
      expect(map.dehydrate('priya called').text, '$fake called');
      expect(map.dehydrate('Priyanka called').text, 'Priyanka called');
    });

    test('possessives are swapped', () {
      final map = mapOf([person('priya', 'Priya')]);
      final fake = fakeFor(map, 'Priya');
      expect(map.dehydrate("Priya's idea").text, "$fake's idea");
      expect(map.dehydrate('Priya’s idea').text, '$fake’s idea');
    });
  });

  group('misspellings (spelling and sound)', () {
    late PseudonymMap map;
    late String priya;
    setUp(() {
      map = mapOf([
        person('priya', 'Priya'),
        person('samantha', 'Samantha', aliases: ['Sam']),
        org('halvorsen', 'Halvorsen Marine Instruments', aliases: ['Halvorsen']),
        org('kestrel', 'Kestrel Bioworks', aliases: ['Kestrel']),
        place('gardiner', 'Gardiner'),
        person('misaki', '美咲', aliases: ['Misaki']),
      ]);
      priya = fakeFor(map, 'Priya');
    });

    test('Pria is Priya', () {
      expect(map.dehydrate('We met Pria at lunch.').text, 'We met $priya at lunch.');
    });

    test('a misspelled name at the start of a sentence is swapped (spike leak)', () {
      expect(map.dehydrate('Pria called me.').text, '$priya called me.');
      expect(
        map.dehydrate('It was late. Pria called me.').text,
        'It was late. $priya called me.',
      );
      expect(map.dehydrate('Samatha is my sister.').text, isNot(contains('Samatha')));
      expect(map.dehydrate('Halverson hired me.').text, isNot(contains('Halverson')));
    });

    test('sound-alike spellings', () {
      expect(map.dehydrate('Samatha came by').text, isNot(contains('Samatha')));
      expect(map.dehydrate('Kestral Bioworks called').text, isNot(contains('Kestral')));
      expect(map.dehydrate('driving to Gardner').text, isNot(contains('Gardner')));
      expect(map.dehydrate('Mizaki texted').text, isNot(contains('Mizaki')));
    });

    test('an ordinary word is not mistaken for a misspelled name', () {
      expect(map.dehydrate('Pray for rain. Prize money.').text, 'Pray for rain. Prize money.');
      expect(map.dehydrate('Same here. Salt and pepper.').text, 'Same here. Salt and pepper.');
    });

    test('a different name one letter away is a near miss we accept', () {
      // Documented trade-off: fuzzy matching replaces; swapping back by the
      // spans restores what was written.
      final d = map.dehydrate('Priyo came.');
      expect(d.restore(), 'Priyo came.');
    });
  });

  group('names that are also words', () {
    late PseudonymMap map;
    late String will, june, rose, may, mark;
    setUp(() {
      map = mapOf([
        person('will', 'Will', gender: Gender.male),
        person('june', 'June', gender: Gender.female),
        person('rose', 'Rose', gender: Gender.female),
        person('may', 'May', gender: Gender.female),
        person('mark', 'Mark', gender: Gender.male),
      ]);
      will = map.dehydrate('Will called.').text.replaceAll(' called.', '');
      june = map.dehydrate('June called.').text.replaceAll(' called.', '');
      rose = map.dehydrate('my aunt Rose in Maine').text.replaceAll('my aunt ', '').replaceAll(' in Maine', '');
      may = map.dehydrate('Then May called.').text.replaceAll('Then ', '').replaceAll(' called.', '');
      mark = map.dehydrate('I told Mark').text.replaceAll('I told ', '');
    });

    test('are swapped when they look like a name', () {
      expect(will, isNot('Will'));
      expect(june, isNot('June'));
      expect(rose, isNot('Rose'));
      expect(may, isNot('May'));
      expect(mark, isNot('Mark'));
      expect(map.dehydrate('Will, my manager, said hi').text, '$will, my manager, said hi');
      expect(map.dehydrate('I asked Will about it').text, 'I asked $will about it');
      expect(map.dehydrate('June is flying in').text, '$june is flying in');
      expect(map.dehydrate('where Rose lives').text, 'where $rose lives');
      expect(map.dehydrate("Mark's birthday").text, "$mark's birthday");
    });

    test('the same words are left alone as ordinary words', () {
      for (final text in [
        'Will you remind me to call?',
        'I will call tomorrow.',
        'The heat rose to ninety.',
        'Prices rose again.',
        "I'm driving up in June.",
        'by June 5 we ship',
        'She may be late.',
        'Maybe in May.',
        'Please mark the date.',
        'a mark on the wall',
        'to mark the occasion',
      ]) {
        expect(map.dehydrate(text).text, text, reason: text);
      }
    });

    test('lowercase uses are never names', () {
      expect(map.dehydrate('will june rose may mark').text, 'will june rose may mark');
    });

    test('a word-name the graph does not know is not learned from a recognizer', () {
      final fresh = PseudonymMap();
      expect(fresh.learn(const [RecognizedName('Will', PseudonymKind.person)]), isFalse);
      expect(fresh.isEmpty, isTrue);
    });

    test('a misspelled word-name is still caught', () {
      expect(map.dehydrate('Wil said so').text, isNot(contains('Wil')));
    });
  });

  group('new names from the recognizer', () {
    test('a learned person gets a consistent fake', () {
      final map = PseudonymMap();
      expect(map.learn(const [RecognizedName('Teodor', PseudonymKind.person)]), isTrue);
      final fake = fakeFor(map, 'Teodor');
      expect(fake, isNot('Teodor'));
      expect(map.dehydrate('Teodor lent me a ladder. Teodor is kind.').text,
          '$fake lent me a ladder. $fake is kind.');
    });

    test('a name already known is not learned twice, even misspelled', () {
      final map = mapOf([person('priya', 'Priya')]);
      expect(map.learn(const [
        RecognizedName('Priya', PseudonymKind.person),
        RecognizedName('Pria', PseudonymKind.person),
      ]), isFalse);
    });

    test('a known first name with more after it extends the same person', () {
      final map = mapOf([person('samantha', 'Samantha')]);
      expect(map.learn(const [RecognizedName('Samantha Lee', PseudonymKind.person)]), isTrue);
      final first = fakeFor(map, 'Samantha');
      expect(fakeFor(map, 'Samantha Lee'), startsWith('$first '));
      expect(map.dehydrate('Samantha Lee called').text, isNot(contains('Lee')));
    });

    test('public places and organizations are not learned', () {
      final map = PseudonymMap();
      expect(map.learn(const [
        RecognizedName('Chicago', PseudonymKind.place),
        RecognizedName('Google', PseudonymKind.org),
      ]), isFalse);
      expect(map.dehydrate('Flying to Chicago for Google').text, 'Flying to Chicago for Google');
    });

    test('small towns and unknown companies are learned', () {
      final map = PseudonymMap();
      map.learn(const [
        RecognizedName('Wiscasset', PseudonymKind.place),
        RecognizedName('Brackett Tools', PseudonymKind.org),
      ]);
      expect(map.dehydrate('Wiscasset and Brackett Tools').text,
          isNot(contains(RegExp('Wiscasset|Brackett'))));
    });

    test('a learned name is adopted when the graph later has it', () {
      final map = PseudonymMap()..learn(const [RecognizedName('Teodor', PseudonymKind.person)]);
      final fake = fakeFor(map, 'Teodor');
      map.sync([person('teodor', 'Teodor', aliases: ['Teo'])]);
      expect(fakeFor(map, 'Teodor'), fake);
      expect(fakeFor(map, 'Teo'), fake);
      expect(map.entityIds, ['teodor']);
    });

    test('a fake that shows up in the text itself is treated as a new name', () {
      final map = mapOf([person('priya', 'Priya')]);
      final fake = fakeFor(map, 'Priya');
      final d = map.dehydrate('My neighbour $fake waved.');
      expect(d.mapChanged, isTrue);
      expect(d.text, isNot(contains(fake)));
      expect(d.restore(), 'My neighbour $fake waved.');
      // And the real Priya still maps to her own fake, not the neighbour's.
      expect(fakeFor(map, 'Priya'), fake);
    });
  });

  group('rehydrate', () {
    late PseudonymMap map;
    late String priya, sam;
    setUp(() {
      map = mapOf([
        person('priya', 'Priya', aliases: ['Priya Raman'], gender: Gender.female),
        person('samantha', 'Samantha', aliases: ['Sam'], gender: Gender.female),
        org('halvorsen', 'Halvorsen Marine Instruments', aliases: ['Halvorsen']),
      ]);
      priya = fakeFor(map, 'Priya');
      sam = fakeFor(map, 'Samantha');
    });

    test('restores names in model output', () {
      expect(map.rehydrate('$priya and $sam met.'), 'Priya and Samantha met.');
    });

    test('handles possessives', () {
      expect(map.rehydrate("$priya's plan, $sam’s plan"), "Priya's plan, Samantha’s plan");
    });

    test('does not depend on the model keeping the casing', () {
      expect(map.rehydrate(priya.toLowerCase()), 'Priya');
      expect(map.rehydrate(priya.toUpperCase()), 'PRIYA');
      expect(map.rehydrate('${priya.toUpperCase()}\'S'), 'PRIYA\'S');
    });

    test('whole words only', () {
      expect(map.rehydrate('${priya}s and x$priya'), '${priya}s and x$priya');
    });

    test('a name the model invented stays as it is', () {
      expect(map.rehydrate('Then Bartholomew arrived with $priya.'),
          'Then Bartholomew arrived with Priya.');
    });

    test('longer stand-ins win over shorter ones', () {
      final full = fakeFor(map, 'Priya Raman');
      expect(map.rehydrate('$full wrote'), 'Priya Raman wrote');
    });

    test('an org alias restores to the org name', () {
      final short = fakeFor(map, 'Halvorsen');
      expect(map.rehydrate('at $short'), 'at Halvorsen');
    });

    test('structural rehydrate walks maps and lists and leaves keys alone', () {
      final json = {
        'entities': [
          {'name': priya, 'description': 'Friend of $sam.', 'mentions': 3},
          {'name': 'Bartholomew', 'ok': true, 'none': null},
        ],
        'title': "$priya's day",
      };
      expect(map.rehydrateJson(json), {
        'entities': [
          {'name': 'Priya', 'description': 'Friend of Samantha.', 'mentions': 3},
          {'name': 'Bartholomew', 'ok': true, 'none': null},
        ],
        'title': "Priya's day",
      });
    });

    test('structural rehydrate can restore id slugs', () {
      final slug = priya.toLowerCase();
      expect(map.rehydrateJson({'id': slug, 'ref': 'other'}, slugs: true),
          {'id': 'priya', 'ref': 'other'});
      // Hyphenated ids: only the stand-in's part changes.
      expect(map.rehydrateJson({'id': '$slug-note'}, slugs: true), {'id': 'priya-note'});
    });
  });

  group('round trip', () {
    test('dehydrate then restore returns the original text exactly', () {
      final map = mapOf([
        person('samantha', 'Samantha', aliases: ['Sam', 'Sammy']),
        person('priya', 'Priya'),
        person('will', 'Will'),
      ]);
      const text = "Sam, well Samantha, and Sammy; Pria and PRIYA's... Will, my manager? Will you?";
      final d = map.dehydrate(text);
      expect(d.text, isNot(text));
      expect(d.roundTripOk, isTrue);
      expect(d.restore(), text);
    });

    test('restore fails closed when the swapped text no longer holds the replacement', () {
      final map = mapOf([person('priya', 'Priya')]);
      final d = map.dehydrate('Priya came');
      expect(d.restore('someone else entirely'), isNull);
    });

    test('text with no known names is returned untouched', () {
      final map = mapOf([person('priya', 'Priya')]);
      final d = map.dehydrate('Nothing to see here.');
      expect(d.text, 'Nothing to see here.');
      expect(d.replacements, isEmpty);
      expect(d.roundTripOk, isTrue);
    });
  });

  group('non-Latin names', () {
    late PseudonymMap map;
    setUp(() {
      map = mapOf([
        person('priya-hi', 'प्रिया', gender: Gender.female),
        person('ivan', 'Иван', gender: Gender.male),
        person('kim', '김민수', gender: Gender.male),
        person('misaki', '美咲', aliases: ['Misaki']),
      ]);
    });

    test('are swapped, and swapped back', () {
      for (final real in ['प्रिया', 'Иван', '김민수', '美咲']) {
        final text = 'Yesterday $real called me.';
        final d = map.dehydrate(text);
        expect(d.text, isNot(contains(real)), reason: real);
        expect(d.text, startsWith('Yesterday '));
        expect(d.restore(), text, reason: real);
        final fake = fakeFor(map, real);
        expect(map.rehydrate('Then $fake left.'), 'Then $real left.', reason: real);
      }
    });

    test('are swapped inside words with attached particles', () {
      final d = map.dehydrate('김민수는 어제 전화했다');
      expect(d.text, isNot(contains('김민수')));
      expect(d.restore(), '김민수는 어제 전화했다');
      final ivan = map.dehydrate('Мы видели Ивана вчера');
      expect(ivan.text, isNot(contains('Иван')));
      expect(ivan.restore(), 'Мы видели Ивана вчера');
    });

    test('a Latin alias of a non-Latin name shares the stand-in', () {
      expect(fakeFor(map, 'Misaki'), fakeFor(map, '美咲'));
    });

    test('mixed text keeps the surrounding script', () {
      final d = map.dehydrate('昨日、美咲と会った。');
      expect(d.text, startsWith('昨日、'));
      expect(d.text, isNot(contains('美咲')));
      expect(d.text, endsWith('と会った。'));
    });
  });

  group('what is private', () {
    Entity e(String name, EntityType type) => Entity(
          id: name.toLowerCase(),
          name: name,
          type: type,
          metadata: {},
          mentions: 1,
          firstSeen: DateTime(2026),
          lastSeen: DateTime(2026),
        );

    test('people, small towns and employers are replaced', () {
      expect(PseudonymEntity.fromEntity(e('Priya', EntityType.person)), isNotNull);
      expect(PseudonymEntity.fromEntity(e('Gardiner', EntityType.place)), isNotNull);
      expect(PseudonymEntity.fromEntity(e('Halvorsen Marine', EntityType.organization)), isNotNull);
      expect(PseudonymEntity.fromEntity(e('14 Elm Street', EntityType.place)), isNotNull);
    });

    test('well-known places and companies are kept', () {
      for (final n in ['Chicago', 'Osaka', 'France', 'Maine', 'New York']) {
        expect(PseudonymEntity.fromEntity(e(n, EntityType.place)), isNull, reason: n);
      }
      for (final n in ['Google', 'Apple', 'Harvard University']) {
        expect(PseudonymEntity.fromEntity(e(n, EntityType.organization)), isNull, reason: n);
      }
    });

    test('events, activities, concepts and feelings are kept', () {
      for (final t in [
        EntityType.event,
        EntityType.activity,
        EntityType.concept,
        EntityType.project,
        EntityType.emotion,
        EntityType.other,
      ]) {
        expect(PseudonymEntity.fromEntity(e('Boston Marathon', t)), isNull);
      }
      final map = mapOf([]);
      expect(map.dehydrate('The Boston Marathon and Python').text, 'The Boston Marathon and Python');
    });

    test('aliases come from the entity metadata', () {
      final ent = Entity(
        id: 's',
        name: 'Samantha',
        type: EntityType.person,
        metadata: {'aliases': ['Sam', 7, 'Sammy']},
        mentions: 1,
        firstSeen: DateTime(2026),
        lastSeen: DateTime(2026),
      );
      expect(PseudonymEntity.fromEntity(ent)!.aliases, ['Sam', 'Sammy']);
      expect(isPrivateIdentifier(PseudonymKind.person, 'Anyone'), isTrue);
    });
  });

  group('sync and forget', () {
    test('sync adds new entities and picks up new aliases without changing fakes', () {
      final map = mapOf([person('samantha', 'Samantha')]);
      final fake = fakeFor(map, 'Samantha');
      expect(map.sync([person('samantha', 'Samantha', aliases: ['Sam'])]), isTrue);
      expect(fakeFor(map, 'Samantha'), fake);
      expect(fakeFor(map, 'Sam'), fake);
      expect(map.sync([person('samantha', 'Samantha', aliases: ['Sam'])]), isFalse);
    });

    test('a renamed entity keeps its fake', () {
      final map = mapOf([person('priya', 'Priya')]);
      final fake = fakeFor(map, 'Priya');
      map.sync([person('priya', 'Priyanka')]);
      expect(fakeFor(map, 'Priyanka'), fake);
    });

    test('forget removes the person: name, aliases and stand-ins', () {
      final map = mapOf([
        person('samantha', 'Samantha', aliases: ['Sam']),
        person('priya', 'Priya'),
      ]);
      final fake = fakeFor(map, 'Samantha');
      final json = map.toJson().toString();
      expect(json, contains('Samantha'));

      expect(map.forget('samantha'), isTrue);
      expect(map.contains('samantha'), isFalse);
      expect(map.toJson().toString(), isNot(contains('Samantha')));
      expect(map.toJson().toString(), isNot(contains('Sam,')));
      // The real name is no longer swapped (the server forgot it too) and
      // the old stand-in no longer maps back to it.
      expect(map.dehydrate('Samantha called').text, 'Samantha called');
      expect(map.rehydrate('$fake called'), '$fake called');
      expect(map.forget('samantha'), isFalse);
    });

    test('a forgotten stand-in is never issued again', () {
      final map = mapOf([person('a', 'Alpha', gender: Gender.female)]);
      final fake = fakeFor(map, 'Alpha');
      map.forget('a');
      for (var i = 0; i < 60; i++) {
        map.sync([person('p$i', 'Realname$i', gender: Gender.female)]);
        expect(fakeFor(map, 'Realname$i'), isNot(fake));
      }
    });

    test('suppressed ids are dropped by sync and not reintroduced', () {
      final map = mapOf([person('samantha', 'Samantha'), person('priya', 'Priya')]);
      map.sync(
        [person('samantha', 'Samantha'), person('priya', 'Priya')],
        suppressed: {'samantha'},
      );
      expect(map.contains('samantha'), isFalse);
      expect(map.contains('priya'), isTrue);
      expect(map.dehydrate('Samantha').text, 'Samantha');
    });

    test('a forgotten stand-in appearing in text is learned as a new name', () {
      final map = mapOf([person('samantha', 'Samantha')]);
      final fake = fakeFor(map, 'Samantha');
      map.forget('samantha');
      // Not in the map any more: left alone, not turned back into Samantha.
      expect(map.rehydrate('$fake waved'), '$fake waved');
    });
  });

  group('persistence format', () {
    test('toJson / fromJson keeps every fake', () {
      final map = mapOf([
        person('priya', 'Priya', aliases: ['Priya Raman']),
        place('gardiner', 'Gardiner'),
        person('misaki', '美咲', aliases: ['Misaki']),
      ])
        ..learn(const [RecognizedName('Teodor', PseudonymKind.person)]);
      final copy = PseudonymMap.fromJson(map.toJson());
      for (final s in ['Priya', 'Priya Raman', 'Gardiner', '美咲', 'Misaki', 'Teodor']) {
        expect(fakeFor(copy, s), fakeFor(map, s), reason: s);
      }
      expect(copy.rehydrate(fakeFor(map, 'Gardiner')), 'Gardiner');
    });

    test('an unknown version is rejected', () {
      expect(() => PseudonymMap.fromJson({'v': 2, 'entries': [], 'retired': []}),
          throwsFormatException);
    });
  });
}
