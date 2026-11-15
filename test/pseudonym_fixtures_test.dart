// LM-55: the pseudonymization spike's fixtures run through the Dart swap.
// Fixtures are copied unchanged from the spike (test/fixtures/pseudonym).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/pseudonym/fake_names.dart';
import 'package:lumen/logic/pseudonym/name_recognizer.dart';
import 'package:lumen/logic/pseudonym/pseudonym_map.dart';
import 'package:lumen/models/entity.dart';

Object _load(String name) =>
    jsonDecode(File('test/fixtures/pseudonym/$name').readAsStringSync()) as Object;

EntityType _type(String t) => switch (t) {
      'person' => EntityType.person,
      'organization' => EntityType.organization,
      'place' => EntityType.place,
      'event' => EntityType.event,
      'activity' => EntityType.activity,
      _ => EntityType.concept,
    };

void main() {
  final entityRows =
      ((_load('entities.json') as Map)['entities'] as List).cast<Map<String, dynamic>>();
  final transcripts = (_load('transcripts.json') as List).cast<Map<String, dynamic>>();
  final truth = _load('ground_truth.json') as Map<String, dynamic>;
  final universe = (truth['universe'] as Map).cast<String, Map<String, dynamic>>();

  // The graph, as the app would hold it. Aliases ride in metadata; the fixture's
  // relational aliases ("my sister") are not names.
  final graph = [
    for (final r in entityRows)
      Entity(
        id: r['id'] as String,
        name: r['name'] as String,
        type: _type(r['type'] as String),
        description: r['description'] as String?,
        metadata: {'aliases': r['aliases']},
        mentions: 1,
        firstSeen: DateTime(2026),
        lastSeen: DateTime(2026),
      ),
  ];
  final swapped = graph
      .map(PseudonymEntity.fromEntity)
      .whereType<PseudonymEntity>()
      .toList();

  // Every spelling of a private identifier that must not reach a prompt:
  // names, aliases and the ASR misspellings the fixtures use.
  final privateIds = {for (final e in swapped) e.id};
  final knownForms = <String>{
    for (final id in privateIds)
      for (final f in (universe[id]!['match'] as List).cast<String>())
        if (!f.toLowerCase().startsWith('my ')) f,
  };

  PseudonymMap freshMap() => PseudonymMap()
    ..sync(swapped, allNames: [for (final e in graph) e.name]);

  List<String> leaks(String text, List<String> traps) {
    var masked = text;
    for (final t in traps) {
      masked = masked.replaceAll(t, ' ' * t.length);
    }
    return [
      for (final f in knownForms)
        if (RegExp(
          RegExp(r'^[\p{Script=Latin}\s]+$', unicode: true).hasMatch(f)
              ? '(?<![\\p{L}\\p{N}_])${RegExp.escape(f)}(?![\\p{L}\\p{N}_])'
              : RegExp.escape(f),
          unicode: true,
          caseSensitive: {'Will', 'June', 'Rose'}.contains(f),
        ).hasMatch(masked))
          f,
    ];
  }

  test('the fixture graph is read as the spike read it', () {
    // 10 private entities; the marathon, Python and running are public.
    expect(swapped.map((e) => e.id).toSet(), {
      'e1', 'e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8', 'e9', 'e10', //
    });
  });

  for (final t in transcripts) {
    final id = t['id'] as String;
    final traps =
        ((truth['transcripts'] as Map)[id]['wordTraps'] as List).cast<String>();
    final texts = [
      t['text'] as String,
      for (final turn in (t['recent'] as List)) (turn as Map)['text'] as String,
    ];

    test('$id: no known name remains after dehydrate', () {
      final map = freshMap();
      for (final text in texts) {
        final out = map.dehydrate(text).text;
        expect(leaks(out, traps), isEmpty, reason: out);
      }
    });

    test('$id: the round trip restores the original text exactly', () {
      final map = freshMap();
      for (final text in texts) {
        final d = map.dehydrate(text);
        expect(d.roundTripOk, isTrue);
        expect(d.restore(), text);
        expect(map.dehydrate(text).text, d.text, reason: 'consistent across calls');
      }
    });

    test('$id: name-words used as ordinary words, and public entities, are untouched', () {
      final map = freshMap();
      final out = map.dehydrate(t['text'] as String).text;
      for (final trap in traps) {
        expect(out, contains(trap));
      }
      for (final keep in ['Boston Marathon', 'Python', 'Chicago', 'Osaka']) {
        if ((t['text'] as String).contains(keep)) expect(out, contains(keep));
      }
    });
  }

  test('model output comes back with the real names (canonical form)', () {
    final map = freshMap();
    final out = map.dehydrate(transcripts[0]['text'] as String).text;
    final back = map.rehydrateModelOutput(out);
    // Aliases come back as the entity's name; nothing else changes.
    expect(back, contains('Samantha, well Samantha'));
    expect(back, contains('Halvorsen Marine Instruments'));
    expect(back, contains('Gardiner'));
    expect(leaks(out, const []).where((f) => f != 'Will' && f != 'June'), isEmpty);
  });

  test('unknown new names are swapped once the recognizer finds them', () {
    final map = freshMap();
    final text = transcripts[1]['text'] as String;
    expect(map.dehydrate(text).text, contains('Teodor'), reason: 'unknown to the graph');
    map.learn(const [RecognizedName('Teodor', PseudonymKind.person)]);
    final d = map.dehydrate(text);
    expect(d.text, isNot(contains('Teodor')));
    expect(d.restore(), text);
  });
}
