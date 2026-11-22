import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/conversation_policy.dart';
import 'package:lumen/logic/session_state.dart';
import 'package:lumen/logic/turn_state.dart' show Speaker;

// EC-04: what this conversation has open, paused, promised and covered, kept
// outside the Live session so a rebuilt one continues instead of restarting.
// Built in code from the finalized turns; no model call.

SessionState _run(List<(Speaker, String)> turns,
    {List<String> known = const ['Priya', 'Lisbon', 'Samsung']}) {
  var state = SessionState.empty;
  for (final (speaker, text) in turns) {
    state = state.observe(speaker: speaker, text: text, known: known);
  }
  return state;
}

void main() {
  test('a question Lumen asked stays open until the user answers it', () {
    final state = _run([
      (Speaker.user, 'Priya is moving to Lisbon.'),
      (Speaker.assistant, 'That is big news. How are you feeling about her moving?'),
    ]);
    expect(state.openThreads, ['How are you feeling about her moving?']);

    final answered = state.observe(
        speaker: Speaker.user,
        text: 'Honestly a bit sad but happy for her.',
        known: const []);
    expect(answered.openThreads, isEmpty);
  });

  test('a filler reply does not answer the question', () {
    final state = _run([
      (Speaker.assistant, 'What did you work on today?'),
      (Speaker.user, 'Hmm.'),
    ]);
    expect(state.openThreads, ['What did you work on today?']);
  });

  test('"not now" pauses the question instead of answering it', () {
    final state = _run([
      (Speaker.assistant, 'Do you want to talk about the move?'),
      (Speaker.user, "Not now, let's talk about it later."),
    ]);
    expect(state.openThreads, isEmpty);
    expect(state.pausedTopics, ['Do you want to talk about the move?']);
  });

  test('only the last question of a turn opens a thread, and at most three stay open', () {
    final state = _run([
      (Speaker.assistant, 'Nice. Was it fun? What did you eat?'),
      (Speaker.assistant, 'Who else was there?'),
      (Speaker.assistant, 'Where did you go after?'),
      (Speaker.assistant, 'How did you get home?'),
    ]);
    expect(state.openThreads, [
      'Who else was there?',
      'Where did you go after?',
      'How did you get home?',
    ]);
    expect(state.asked, contains('What did you eat?'));
  });

  test('Lumen\'s promises are kept as commitments', () {
    final state = _run([
      (Speaker.assistant,
          "Good luck with the interview. I'll ask you how it went next time."),
    ]);
    expect(state.commitments, ["I'll ask you how it went next time."]);
  });

  test('the register follows the user\'s latest feeling words', () {
    var state = _run([(Speaker.user, "I'm so stressed about the final.")]);
    expect(state.register, 'stressed');
    state = state.observe(
        speaker: Speaker.user, text: 'The weather is nice.', known: const []);
    expect(state.register, 'stressed', reason: 'no feeling words: unchanged');
    state = state.observe(
        speaker: Speaker.user, text: 'Actually I feel really excited now!', known: const []);
    expect(state.register, 'upbeat');
  });

  test('names either side said are covered, once, in order', () {
    final state = _run([
      (Speaker.user, 'Priya called me.'),
      (Speaker.assistant, 'How is Priya doing in Lisbon?'),
    ]);
    expect(state.covered, ['Priya', 'Lisbon']);
  });

  test('round-trips through JSON, and bad stored data starts empty', () {
    final state = _run([
      (Speaker.user, "I'm tired. Priya called."),
      (Speaker.assistant, "I'll remind you tomorrow. What did she say?"),
    ]);
    expect(SessionState.fromJson(state.toJson()).toJson(), state.toJson());
    expect(SessionState.fromJson({'openThreads': 'nope'}).toJson(),
        SessionState.empty.toJson());
    expect(SessionState.fromJson(null).isEmpty, isTrue);
  });

  test('a forgotten name is redacted everywhere in the record', () {
    final state = _run([
      (Speaker.user, 'Priya called.'),
      (Speaker.assistant, "I'll ask about Priya later. How is Priya?"),
    ]);
    final redacted = state.redacted((text) => text.replaceAll('Priya', 'someone'));
    expect(redacted.toJson().toString(), isNot(contains('Priya')));
    expect(redacted.covered, isNot(contains('someone')),
        reason: 'a forgotten topic is not "covered"; it is gone');
  });

  test('the prompt tells Lumen to continue open threads, not re-ask them', () {
    expect(geminiLiveSystemInstruction, contains('sessionState'));
    expect(geminiLiveSystemInstruction,
        contains("pick up the newest one naturally, don't ask it again"));
    expect(geminiLiveSystemInstruction,
        contains("leave them unless the user brings them back"));
  });
}
