import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/slugify.dart';

void main() {
  test('slugifies common names', () {
    expect(slugify('Project Atlas'), 'project-atlas');
    expect(slugify('CS246'), 'cs246');
    expect(slugify('Héros'), 'heros');
  });

  test('empty names get a generated id prefix', () {
    expect(slugify(''), startsWith('e-'));
  });
}
