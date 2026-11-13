// R34: the erase confirmation highlights, in a sample passage, the words the
// server would replace with "someone".
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/logic/erase_highlight.dart';

String marked(List<EraseSpan> spans) =>
    spans.map((s) => s.erased ? '[${s.text}]' : s.text).join();

void main() {
  test('one name in the middle', () {
    expect(marked(eraseSpans('I met Maya Chen today.', 'I met someone today.')),
        'I met [Maya Chen] today.');
  });

  test('at the start and the end, more than once', () {
    expect(
        marked(eraseSpans('Maya Chen called. How is maya chen',
            'someone called. How is someone')),
        '[Maya Chen] called. How is [maya chen]');
  });

  test('a name that starts like "someone"', () {
    expect(marked(eraseSpans('met sara lee there', 'met someone there')),
        'met [sara lee] there');
  });

  test('"someone" the user said is not highlighted', () {
    expect(
        marked(eraseSpans(
            'someone told Maya Chen.', 'someone told someone.')),
        'someone told [Maya Chen].');
  });

  test('when the two do not line up, nothing is highlighted', () {
    expect(marked(eraseSpans('abc', 'xyz')), 'abc');
  });

  test('excerpt keeps the first highlight in view', () {
    final long = '${'word ' * 40}Maya Chen said hi.';
    final spans = eraseSpans(long, '${'word ' * 40}someone said hi.');
    final cut = excerptAroundFirstErase(spans, before: 20);
    expect(marked(cut), startsWith('…'));
    expect(marked(cut), contains('[Maya Chen] said hi.'));
    expect(marked(cut).length, lessThan(60));
  });
}
