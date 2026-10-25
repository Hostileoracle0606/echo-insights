// The trie highlighter must produce exactly the runs the per-term regex
// highlighter did. The original algorithm is kept in
// support/legacy_highlighter.dart as the reference, and both run over fixed
// edge cases and random texts.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/entity_highlighter.dart';
import 'package:lumen/models/entity.dart';

import 'support/legacy_highlighter.dart';

String show(List<TextRun> runs) =>
    runs.map((r) => r.type == null ? r.text : '[${r.text}|${r.type!.name}]').join();

void main() {
  final terms = [
    const HighlightTerm('Tidepool', EntityType.project),
    const HighlightTerm('Tidepool launch', EntityType.event),
    const HighlightTerm('Maya', EntityType.person),
    const HighlightTerm('maya', EntityType.place),
    const HighlightTerm('CI', EntityType.project),
    const HighlightTerm('Café Lune', EntityType.place),
    const HighlightTerm('a a', EntityType.concept),
    const HighlightTerm('a a b', EntityType.concept),
    const HighlightTerm('C++', EntityType.concept),
    const HighlightTerm('Σίσυφος', EntityType.person),
  ];

  test('fixed edge cases', () {
    for (final text in [
      'Maya said the Tidepool launch slipped. maya agreed; tidepool is fine.',
      'MCI isn’t CI. CI-fix landed (CI). Café Lune at 9. CAFÉ LUNE!',
      'Tidepool launchpad and Tidepool, launch!',
      'a a a a b a a',
      'I write C++ and c++ daily; C+++ is not a thing.',
      'ΣΊΣΥΦΟΣ and Σίσυφος and σίσυφος.',
      'straße STRASSE ſmall µ',
      '',
      'no names here',
    ]) {
      expect(show(highlightRuns(text, terms)), show(referenceRuns(text, terms)),
          reason: text);
    }
  });

  test('random texts and term sets', () {
    final random = Random(99);
    const words = ['Maya', 'maya', 'CI', 'Tidepool', 'launch', 'a', 'b', 'Café',
      'Lune', 'x', 'C++', 'the', 'and', 'Entity', '7', '12', '-', ',', '(', ')'];
    for (var round = 0; round < 300; round++) {
      final pool = [
        for (var i = 0; i < 1 + random.nextInt(8); i++)
          HighlightTerm(
            List.generate(1 + random.nextInt(3), (_) => words[random.nextInt(words.length)]).join(' '),
            EntityType.values[random.nextInt(EntityType.values.length)],
          ),
      ];
      final text = List.generate(random.nextInt(25), (_) => words[random.nextInt(words.length)])
          .join(random.nextBool() ? ' ' : '');
      expect(show(highlightRuns(text, pool)), show(referenceRuns(text, pool)),
          reason: 'text="$text" terms=${pool.map((t) => t.text).toList()}');
    }
  });
}
