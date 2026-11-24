import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/conversation_policy.dart';
import 'package:lumen/providers/journal_provider.dart';

/// Lumen kept steering back to one remembered person: both the prompt and
/// the tool told it to recall memory whenever that would make it "sound like
/// you remember", so it reached into memory to find something to say.
void main() {
  final toolDescription =
      ((JournalNotifier.liveTools.single['function_declarations'] as List)
          .cast<Map>()
          .firstWhere((d) => d['name'] == 'get_relevant_memory'))['description'] as String;

  test('memory is recalled only when the user refers back', () {
    expect(geminiLiveSystemInstruction,
        contains('Call it only when the user refers back'));
    expect(toolDescription, contains('only when the user refers back'));
  });

  test('memory is never a way to find something to talk about', () {
    expect(geminiLiveSystemInstruction,
        isNot(contains('sound like you remember')));
    expect(toolDescription, isNot(contains('grounding your reply')));
    expect(
        geminiLiveSystemInstruction,
        contains(
            "never bring up something it returned that the user didn't ask about"));
    expect(toolDescription, contains('not to find something to talk about'));
  });

  test('exact questions go to the tool, never a guess (EC-06)', () {
    expect(geminiLiveSystemInstruction,
        contains('an exact value, a total or difference'));
    expect(geminiLiveSystemInstruction,
        contains('Never guess a number or a date.'));
  });
}
