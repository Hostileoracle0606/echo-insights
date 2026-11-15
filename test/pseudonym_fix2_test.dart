// LM-55 fix round 2: word-name parts of full names, "to Will", NFC both ways.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/pseudonym/fake_names.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';

PseudonymEntity person(String id, String name, {Gender? gender}) => PseudonymEntity(
    id: id, name: name, kind: PseudonymKind.person, gender: gender);

PseudonymMap mapOf(Iterable<PseudonymEntity> e) => PseudonymMap()..sync(e);
String fakeFor(PseudonymMap m, String real) => m.dehydrate(real).text;

void main() {
  group('word-names inside full names', () {
    test('Mark Chen: Mark is swapped where it is a name', () {
      final m = mapOf([person('m', 'Mark Chen')]);
      final fake = fakeFor(m, 'Mark Chen').split(' ').first;
      for (final t in [
        'Mark said it was fine',
        'I met Mark',
        "Mark's here",
        'my friend Mark',
        'a friend of Mark',
        'I talked to Mark yesterday',
      ]) {
        final out = m.dehydrate(t).text;
        expect(out, isNot(contains('Mark')), reason: t);
        expect(out, contains(fake), reason: t);
      }
    });

    test('and left alone as an ordinary word', () {
      final m = mapOf([person('m', 'Mark Chen')]);
      for (final t in [
        'Please mark the date.',
        'a mark on the wall',
        'to mark the occasion',
        'Mark the date, please.',
      ]) {
        expect(m.dehydrate(t).text, t, reason: t);
      }
    });

    test('Rose, Will and May as first or last words', () {
      final rose = mapOf([person('r', 'Rose Alvarez')]);
      expect(rose.dehydrate('Rose called me').text, isNot(contains('Rose')));
      expect(rose.dehydrate('The heat rose. Prices rose again.').text,
          'The heat rose. Prices rose again.');
      final will = mapOf([person('w', 'Will Parker')]);
      expect(will.dehydrate('Will is late. I asked Will.').text, isNot(contains('Will')));
      expect(will.dehydrate('Will you call me? I will call.').text,
          'Will you call me? I will call.');
      final may = mapOf([person('y', 'Amy May')]);
      expect(may.dehydrate('Then May called.').text, isNot(contains('May')));
      expect(may.dehydrate('She may be late; see you in May.').text,
          'She may be late; see you in May.');
      final last = mapOf([person('t', 'Taylor Rose')]);
      expect(last.dehydrate('Rose said hi').text, isNot(contains('Rose')));
    });

    test('ordinary words that are parts of names are still guarded', () {
      final m = mapOf([person('m', 'Mark Hill')]);
      expect(m.dehydrate('The hill is steep. Hill Street is closed.').text,
          'The hill is steep. Hill Street is closed.');
    });
  });

  group('names after "to" and other small words', () {
    test('I talked to Will yesterday', () {
      final m = mapOf([person('w', 'Will', gender: Gender.male)]);
      final fake = fakeFor(m, 'Will');
      expect(m.dehydrate('I talked to Will yesterday').text, 'I talked to $fake yesterday');
      expect(m.dehydrate('going to will it into being').text, 'going to will it into being');
    });

    test('a capitalised word-name mid-sentence is a name after any small word', () {
      final m = mapOf([person('w', 'Will'), person('r', 'Rose'), person('k', 'Mark')]);
      for (final t in [
        'Tell him that Will is coming',
        'Is it Will?',
        'What would Will say',
        'Was it Rose who called',
        'I know that Mark is here',
        'Could you ask Mark',
      ]) {
        expect(m.dehydrate(t).text, isNot(contains(RegExp('Will|Rose|Mark'))), reason: t);
      }
    });

    test('ALL CAPS keeps the aux rules', () {
      final m = mapOf([person('w', 'Will')]);
      expect(m.dehydrate('I WILL CALL').text, 'I WILL CALL');
      expect(m.dehydrate('TALKED TO WILL').text, isNot(contains('WILL')));
    });
  });

  group('NFC both ways', () {
    test('a name stored decomposed matches precomposed text', () {
      final m = mapOf([person('j', 'José García')]);
      final fake = fakeFor(m, 'José García').split(' ').first;
      expect(m.dehydrate('José called').text, '$fake called');
      expect(m.dehydrate('García called').text, '$fake called');
      expect(m.dehydrate('José García called').text, isNot(contains('Garc')));
      final d = m.dehydrate('José García called');
      expect(d.restore(), 'José García called');
    });

    test('precomposed graph, decomposed text still works', () {
      final m = mapOf([person('j', 'José García')]);
      final d = m.dehydrate('José García called');
      expect(d.text, isNot(contains('́')));
      expect(d.restore(), 'José García called');
    });

    test('a misspelling is measured on composed letters', () {
      final m = mapOf([person('j', 'José')]);
      expect(m.dehydrate('Josè called').text, isNot(contains('Jos')));
    });
  });
}
