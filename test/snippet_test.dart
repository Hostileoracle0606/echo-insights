import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/snippet.dart';

void main() {
  test('short text is returned unchanged', () {
    expect(snippet('Maya flagged the slip.'), 'Maya flagged the slip.');
  });

  test('whitespace is collapsed and trimmed', () {
    expect(
      snippet('  Maya\n\nflagged\t the   slip.  '),
      'Maya flagged the slip.',
    );
  });

  test('long text is truncated to max with an ellipsis on a word boundary', () {
    final long = List.filled(60, 'word').join(' ');
    final out = snippet(long, max: 140);

    expect(out.length, lessThanOrEqualTo(141));
    expect(out.endsWith('…'), isTrue);
    expect(out, isNot(contains('  ')));
    expect(out.substring(0, out.length - 1).endsWith('word'), isTrue);
  });
}
