import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/slugify.dart';

void main() {
  test('slugifies common names', () {
    expect(slugify('Project Atlas'), 'project-atlas');
    expect(slugify('CS246'), 'cs246');
    expect(slugify('Héros'), 'heros');
  });

  test('names with no Latin letters get a stable id', () {
    expect(slugify('प्रिया'), 'प्रिया');
    expect(slugify('Иван'), 'иван');
    expect(slugify('李雷'), '李雷');
    expect(slugify('Иван Петров'), 'иван-петров');
    expect(slugify('Иван'), slugify('Иван'), reason: 'not time-based');
  });

  test('ids of Latin names are what they always were', () {
    expect(slugify('Žofia'), 'ofia');
    expect(slugify("O'Brien"), 'o-brien');
    expect(slugify('St. John'), 'st-john');
    expect(slugify('Zoë Müller'), 'zoe-muller');
  });

  test('an id is at most 60 characters, whole ones', () {
    expect(slugify('李' * 80).runes.length, 60);
  });

  test('empty names get a generated id prefix', () {
    expect(slugify(''), startsWith('e-'));
  });
}
