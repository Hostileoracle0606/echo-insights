// Wire contract for notebooks.conversation_mode / mode_context (LM-01): the
// Dart enum must spell each mode exactly as the SQL check constraint does
// (proven against Postgres by supabase/tests/database/conversation_modes_test.sql),
// and a missing or unknown server value must never crash the app.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/conversation_mode.dart';
import 'package:lumen/models/notebook.dart';
import 'package:lumen/services/supabase_service.dart';

Map<String, dynamic> _row({Object? mode = _absent, Object? context = _absent}) {
  return {
    'id': 'nb-1',
    'user_id': 'user-1',
    'title': 'Untitled',
    'title_source': 'auto',
    'started_at': '2026-10-21T09:00:00.000Z',
    'ended_at': null,
    'entity_count': 0,
    'summary': null,
    'created_at': '2026-10-21T09:00:00.000Z',
    'updated_at': '2026-10-21T09:00:00.000Z',
    if (mode != _absent) 'conversation_mode': mode,
    if (context != _absent) 'mode_context': context,
  };
}

const _absent = Object();

void main() {
  const wireNames = {
    ConversationMode.weeklyDebrief: 'weekly_debrief',
    ConversationMode.sessionPrep: 'session_prep',
    ConversationMode.whatLanded: 'what_landed',
    ConversationMode.firstSession: 'first_session',
    ConversationMode.justTalk: 'just_talk',
  };

  test('the wire-name table covers every mode', () {
    expect(wireNames.keys, unorderedEquals(ConversationMode.values));
  });

  group('wire names', () {
    for (final MapEntry(key: mode, value: wire) in wireNames.entries) {
      test('$mode round-trips as $wire', () {
        expect(mode.wireName, wire);

        final parsed = Notebook.fromJson(
          _row(mode: wire, context: {'weekOf': '2026-10-23'}),
        );
        expect(parsed.conversationMode, mode);
        expect(parsed.modeContext, {'weekOf': '2026-10-23'});

        final json = parsed.toJson();
        expect(json['conversation_mode'], wire);
        expect(json['mode_context'], {'weekOf': '2026-10-23'});
        expect(json.containsKey('mode'), isFalse);
      });
    }
  });

  group('tolerant parsing', () {
    test('a row with no conversation_mode or mode_context is justTalk, {}', () {
      final parsed = Notebook.fromJson(_row());
      expect(parsed.conversationMode, ConversationMode.justTalk);
      expect(parsed.modeContext, isEmpty);
    });

    test('an unknown conversation_mode is justTalk', () {
      final parsed = Notebook.fromJson(_row(mode: 'some_future_mode'));
      expect(parsed.conversationMode, ConversationMode.justTalk);
    });

    test('the constructor defaults to justTalk with no context', () {
      final notebook = Notebook(
        id: 'nb-1',
        userId: 'user-1',
        title: 'Untitled',
        titleSource: 'auto',
        startedAt: DateTime.utc(2026, 10, 21),
        entityCount: 0,
        createdAt: DateTime.utc(2026, 10, 21),
        updatedAt: DateTime.utc(2026, 10, 21),
      );
      expect(notebook.conversationMode, ConversationMode.justTalk);
      expect(notebook.modeContext, isEmpty);
    });
  });

  group('createNotebook insert row', () {
    final startedAt = DateTime.utc(2026, 10, 23, 9);

    test('sends the mode and context it was given', () {
      final row = SupabaseService.newNotebookRow(
        userId: 'user-1',
        startedAt: startedAt,
        conversationMode: ConversationMode.weeklyDebrief,
        modeContext: const {'weekOf': '2026-10-23'},
      );
      expect(row, {
        'user_id': 'user-1',
        'title': 'Untitled',
        'started_at': '2026-10-23T09:00:00.000Z',
        'conversation_mode': 'weekly_debrief',
        'mode_context': {'weekOf': '2026-10-23'},
      });
    });

    test('defaults to just_talk with {} context', () {
      final row = SupabaseService.newNotebookRow(
        userId: 'user-1',
        startedAt: startedAt,
      );
      expect(row['conversation_mode'], 'just_talk');
      expect(row['mode_context'], isEmpty);
      expect(row.containsKey('mode'), isFalse);
    });
  });
}
