import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/filler_words.dart';
import 'package:lumen/logic/noise_filter.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/entity.dart';
import 'package:lumen/models/graph_patch.dart';

TurnMachine _machine() {
  var turnSeq = 0;
  var reqSeq = 0;
  var clock = 0;
  return TurnMachine(
    now: () => DateTime.utc(2026, 1, 1)
        .add(Duration(seconds: clock++))
        .toIso8601String(),
    newTurnId: () => 'turn-${++turnSeq}',
    newRequestId: () => 'req-${++reqSeq}',
  );
}

void main() {
  group('stripFillers', () {
    test('drops hesitation sounds and the commas around them', () {
      expect(
        stripFillers('Um, my savings goal is, uh, three fifty now.'),
        'My savings goal is three fifty now.',
      );
      expect(stripFillers('So umm I think, erm, Kyoto.'), 'So I think Kyoto.');
      expect(stripFillers('Hmm... maybe Maya? Mm, yes.'), 'Maybe Maya? Yes.');
      expect(stripFillers('UH I mean UHM, Dune'), 'I mean Dune');
    });

    test('keeps words that only look like fillers', () {
      for (final text in [
        'I like Dune.',
        'My umbrella broke.',
        'Uh-huh, that is right.',
        'Well, it went fine.',
        'Oh no.',
      ]) {
        expect(stripFillers(text), text);
      }
    });

    test('a turn of only fillers becomes empty', () {
      expect(stripFillers('Um.'), '');
      expect(stripFillers('uh, um... hmm'), '');
    });
  });

  group('turns', () {
    test('a spoken user turn is saved and extracted without fillers', () {
      final m = _machine()
        ..dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'))
        ..dispatch(const FinalTranscript(
          speaker: Speaker.user,
          text: 'Um, Maya starts her, uh, new job Monday.',
        ));
      final effects = m.dispatch(const TurnCompleted(speaker: Speaker.user));

      expect(m.state.conversation.single.text,
          'Maya starts her new job Monday.');
      expect(effects.whereType<StartDurableExtraction>().single.transcript,
          'Maya starts her new job Monday.');
    });

    test('a user turn of only fillers is not saved or extracted', () {
      final m = _machine()
        ..dispatch(const SessionStarted(sessionId: 's1', notebookId: 'nb1'))
        ..dispatch(const FinalTranscript(speaker: Speaker.user, text: 'Um...'));
      final effects = m.dispatch(const TurnCompleted(speaker: Speaker.user));

      expect(effects.whereType<StartDurableExtraction>(), isEmpty);
      expect(m.state.conversation, isEmpty);
      expect(m.state.pending, isEmpty);
    });
  });

  test('graph patches drop filler entities and their relations', () {
    const patch = GraphPatch(
      entities: [
        EntityPatch(name: 'Um', type: EntityType.other),
        EntityPatch(name: 'uh', type: EntityType.concept),
        EntityPatch(name: 'Hmm', type: EntityType.other),
        EntityPatch(name: 'you know', type: EntityType.concept),
        EntityPatch(name: 'Maya', type: EntityType.person),
      ],
      relations: [
        RelationPatch(source: 'Maya', target: 'Um', label: 'said'),
      ],
      supersedes: [],
    );

    final filtered = filterNoise(patch);

    expect(filtered.entities.map((entity) => entity.name), ['Maya']);
    expect(filtered.relations, isEmpty);
  });
}
