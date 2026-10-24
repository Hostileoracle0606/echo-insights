// The Dart side of contracts/session-card-v1: every fixture parses, so the
// closing screens (LM-16, LM-19, LM-25) can be built against them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/conversation_mode.dart';
import 'package:lumen/models/entity.dart' show EntityType;
import 'package:lumen/models/session_card.dart';

Map<String, dynamic> _fixture(String mode) => jsonDecode(
      File('contracts/fixtures/session-card-v1.$mode.json').readAsStringSync(),
    ) as Map<String, dynamic>;

void main() {
  test('there is a fixture for every conversation mode', () {
    for (final mode in ConversationMode.values) {
      expect(
        File('contracts/fixtures/session-card-v1.${mode.wireName}.json')
            .existsSync(),
        isTrue,
        reason: mode.wireName,
      );
    }
  });

  for (final mode in ConversationMode.values) {
    test('the ${mode.wireName} fixture parses and round-trips', () {
      final json = _fixture(mode.wireName);
      final card = SessionCard.fromJson(json);

      expect(card.version, 1);
      expect(card.conversationMode, mode);
      expect(card.notebookId, json['notebookId']);
      expect(card.sourceRevision, json['sourceRevision']);
      expect(card.title, isNotEmpty);
      expect(card.summary, isNotEmpty);
      expect(card.remember.length, (json['remember'] as List).length);
      expect(jsonDecode(jsonEncode(card.toJson())), json);
    });
  }

  test('Just talk notes and the remember list are typed', () {
    final card = SessionCard.fromJson(_fixture('just_talk'));

    expect(card.notes, hasLength(3));
    expect(card.notes.first, startsWith('Maya is moving to Brooklyn'));
    expect(card.modeFields.keys, ['notes']);
    final maya = card.remember.first;
    expect(maya.entityId, 'maya');
    expect(maya.type, EntityType.person);
    expect(maya.isNew, isFalse);
    final brooklyn = card.remember.last;
    expect(brooklyn.note, isNull);
    expect(brooklyn.isNew, isTrue);
  });

  test("other modes keep their fields raw and have no notes", () {
    final card = SessionCard.fromJson(_fixture('weekly_debrief'));

    expect(card.notes, isEmpty);
    expect(
      card.modeFields.keys,
      containsAll(['weekOf', 'nextDebriefOn', 'briefTotal', 'wins', 'openItems']),
    );
    expect((card.modeFields['wins'] as List).first['top'], isTrue);
  });

  test('an unknown entity type reads as other', () {
    final json = _fixture('just_talk');
    (json['remember'] as List).first['type'] = 'planet';
    expect(SessionCard.fromJson(json).remember.first.type, EntityType.other);
  });

  test('another version or a malformed card is refused', () {
    expect(
      () => SessionCard.fromJson({..._fixture('just_talk'), 'version': 2}),
      throwsFormatException,
    );
    expect(
      () => SessionCard.fromJson({..._fixture('just_talk'), 'conversationMode': 'chat'}),
      throwsFormatException,
    );
    expect(
      () => SessionCard.fromJson({..._fixture('just_talk'), 'remember': [{'name': 'x'}]}),
      throwsFormatException,
    );
    expect(() => SessionCard.fromJson('card'), throwsFormatException);
  });
}
