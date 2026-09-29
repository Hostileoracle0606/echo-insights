import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/resume_context.dart';
import 'package:lumen/logic/turn_state.dart';
import 'package:lumen/models/journal_entry.dart';

ConversationTurn turn(int n, Speaker role, String text) => ConversationTurn(
      turnId: 't$n',
      role: role,
      text: text,
      createdAt: '2026-09-28T12:00:${n.toString().padLeft(2, '0')}Z',
    );

JournalEntry entry(String id, String text, int minute) => JournalEntry(
      id: id,
      text: text,
      createdAt: DateTime.utc(2026, 9, 20, 12, minute),
      entityIds: const [],
      relationIds: const [],
    );

void main() {
  test('a notebook with no turns and no entries is a new conversation', () {
    expect(continuesConversation(conversation: const [], entries: const []),
        isFalse);
    expect(
      continuesConversation(conversation: const [], entries: [entry('e', 'x', 1)]),
      isTrue,
    );
  });

  test('uses this run\'s turns with their roles, newest last', () {
    final context = resumeContext(
      conversation: [
        turn(1, Speaker.user, 'I met Maya.'),
        turn(2, Speaker.assistant, 'How did it go?'),
      ],
      entries: [entry('e', 'older entry', 1)],
    );

    expect(context, [
      (fromUser: true, text: 'I met Maya.'),
      (fromUser: false, text: 'How did it go?'),
    ]);
  });

  test('falls back to saved entries, oldest first, as the user\'s words', () {
    final context = resumeContext(
      conversation: const [],
      entries: [entry('b', 'second', 2), entry('a', 'first', 1)],
    );

    expect(context, [
      (fromUser: true, text: 'first'),
      (fromUser: true, text: 'second'),
    ]);
  });

  test('keeps the most recent turns within the turn and size caps', () {
    final many = [
      for (var i = 0; i < 30; i++) turn(i, Speaker.user, 'turn $i'),
    ];
    final byCount = resumeContext(conversation: many, entries: const []);
    expect(byCount, hasLength(20));
    expect(byCount.first.text, 'turn 10');
    expect(byCount.last.text, 'turn 29');

    final bySize = resumeContext(
      conversation: [
        turn(1, Speaker.user, 'a' * 50),
        turn(2, Speaker.user, 'b' * 50),
      ],
      entries: const [],
      maxChars: 60,
    );
    expect(bySize.single.text, 'b' * 50);
  });
}
