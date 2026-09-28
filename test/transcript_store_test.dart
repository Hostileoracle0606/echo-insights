import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/services/transcript_store.dart';

void main() {
  test('a turn round-trips through its conversation_turns row', () {
    const turn = ConversationTurn(
      turnId: 'turn-1',
      role: Speaker.assistant,
      text: 'How did it go?',
      createdAt: '2026-09-28T12:00:05.000Z',
      startedAt: '2026-09-28T12:00:02.000Z',
    );

    final row = turnToRow('nb-1', turn);

    expect(row, {
      'notebook_id': 'nb-1',
      'turn_id': 'turn-1',
      'speaker': 'assistant',
      'text': 'How did it go?',
      'spoken_at': '2026-09-28T12:00:02.000Z',
    });
    expect(row.containsKey('user_id'), isFalse,
        reason: 'the server sets the owner from the caller');

    // Postgres returns timestamptz with an offset.
    final back = turnFromRow({...row, 'spoken_at': '2026-09-28 12:00:02+00'});
    expect(back.turnId, 'turn-1');
    expect(back.role, Speaker.assistant);
    expect(back.text, 'How did it go?');
    expect(back.startedAt, '2026-09-28T12:00:02.000Z');
  });

  test('user turns are stored as the user speaker', () {
    const turn = ConversationTurn(
      turnId: 't',
      role: Speaker.user,
      text: 'hi',
      createdAt: '2026-09-28T12:00:00Z',
    );
    expect(turnToRow('nb', turn)['speaker'], 'user');
    expect(turnFromRow(turnToRow('nb', turn)).role, Speaker.user);
  });
}
