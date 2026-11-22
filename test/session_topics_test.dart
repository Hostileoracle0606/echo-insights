import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/session_topics.dart';

void main() {
  group('probedThisSession', () {
    test('names Lumen has said this session, in the order known', () {
      expect(
        probedThisSession(
          lumenSaid: [
            "How's Priya feeling about the move?",
            'What kind of work is she doing in lisbon?',
          ],
          known: ['Lisbon', 'Priya', 'Samsung'],
        ),
        ['Lisbon', 'Priya'],
      );
    });

    test('matches whole words only', () {
      expect(
        probedThisSession(
          lumenSaid: ['Are you feeling anxious about the launch?'],
          known: ['Ann', 'launch', 'Al'],
        ),
        ['launch'],
      );
    });

    test('names recalled from memory count, written as slugs', () {
      // get_relevant_memory returns entity ids; the person came from an
      // earlier notebook, so the current graph doesn't know her.
      expect(
        probedThisSession(
          lumenSaid: ["Is Priya Raman's move still on?"],
          known: ['Samsung'],
          recalledIds: ['priya-raman', 'samsung'],
        ),
        ['priya raman'],
      );
    });

    test('nothing said, nothing probed', () {
      expect(probedThisSession(lumenSaid: const [], known: ['Priya']), isEmpty);
    });
  });

  test('recentAgentQuestions keeps the latest lines, oldest first', () {
    final said = [for (var i = 0; i < 11; i++) 'Question $i?'];
    expect(
      recentLines(said),
      [for (var i = 3; i < 11; i++) 'Question $i?'],
    );
    expect(recentLines(['Only one?']), ['Only one?']);
  });
}
