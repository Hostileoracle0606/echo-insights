import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/entity_highlighter.dart';
import 'package:lumen/models/entity.dart';

List<(String, EntityType?)> _runs(String text, List<HighlightTerm> terms) => [
      for (final run in highlightRuns(text, terms)) (run.text, run.type),
    ];

void main() {
  const maya = HighlightTerm('Maya', EntityType.person);
  const lisbon = HighlightTerm('Lisbon', EntityType.place);

  test('plain text with no terms is a single unmarked run', () {
    expect(_runs('Just a day.', const []), [('Just a day.', null)]);
  });

  test('marks each mention, keeping the text between them', () {
    expect(_runs('Maya flew to Lisbon.', const [maya, lisbon]), [
      ('Maya', EntityType.person),
      (' flew to ', null),
      ('Lisbon', EntityType.place),
      ('.', null),
    ]);
  });

  test('matches case-insensitively but keeps the spoken casing', () {
    expect(_runs('i told MAYA', const [maya]), [
      ('i told ', null),
      ('MAYA', EntityType.person),
    ]);
  });

  test('only whole words match', () {
    expect(_runs('Mayan ruins and Amaya', const [maya]), [
      ('Mayan ruins and Amaya', null),
    ]);
  });

  test('a possessive still marks the name', () {
    expect(_runs("Maya's offer", const [maya]), [
      ('Maya', EntityType.person),
      ("'s offer", null),
    ]);
  });

  test('the longest overlapping term wins', () {
    const tidepool = HighlightTerm('Tidepool', EntityType.project);
    const launch = HighlightTerm('Tidepool launch', EntityType.event);
    expect(_runs('the Tidepool launch slipped', const [tidepool, launch]), [
      ('the ', null),
      ('Tidepool launch', EntityType.event),
      (' slipped', null),
    ]);
  });

  test('runs always rebuild the original text exactly', () {
    const text = 'Maya, Lisbon, maya and lisbon again';
    final joined =
        highlightRuns(text, const [maya, lisbon]).map((r) => r.text).join();
    expect(joined, text);
  });

  test('termsForEntities skips blank and one-letter names', () {
    final now = DateTime(2026);
    Entity e(String name) => Entity(
          id: name,
          name: name,
          type: EntityType.concept,
          metadata: const {},
          mentions: 1,
          firstSeen: now,
          lastSeen: now,
        );
    final terms = termsForEntities([e('Ai'), e('X'), e('  ')]);
    expect(terms.map((t) => t.text), ['Ai']);
  });
}
