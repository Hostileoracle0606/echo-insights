/// R34: which words of a sample passage the erase would replace. The server
/// sends each passage as it is ([before]) and as it would be ([after], each
/// match replaced by "someone"); lining the two up gives the spans to
/// highlight, without the app needing to know how the name was matched.
class EraseSpan {
  const EraseSpan(this.text, {this.erased = false});
  final String text;
  final bool erased;
}

const _someone = 'someone';

/// [before] split into plain and erased spans. When the two can't be lined
/// up, the whole passage comes back plain: a sample, never a wrong highlight.
List<EraseSpan> eraseSpans(String before, String after) {
  final spans = <EraseSpan>[];
  final plain = StringBuffer();
  var i = 0;
  var j = 0;
  void flush() {
    if (plain.isEmpty) return;
    spans.add(EraseSpan(plain.toString()));
    plain.clear();
  }

  while (i < before.length || j < after.length) {
    final replaced =
        after.startsWith(_someone, j) && !before.startsWith(_someone, i);
    if (!replaced) {
      if (i < before.length &&
          j < after.length &&
          before.codeUnitAt(i) == after.codeUnitAt(j)) {
        plain.writeCharCode(before.codeUnitAt(i));
        i++;
        j++;
        continue;
      }
      return [EraseSpan(before)];
    }
    // A replacement starts here: the name runs to where the rest lines up.
    final rest = after.substring(j + _someone.length);
    final next = rest.indexOf(_someone);
    final probe = rest.substring(
        0,
        next < 0
            ? (rest.length < 16 ? rest.length : 16)
            : (next < 16 ? next : 16));
    int end;
    if (probe.isEmpty) {
      end = next == 0 ? -1 : before.length;
    } else {
      end = before.indexOf(probe, i + 1);
    }
    if (end <= i) return [EraseSpan(before)];
    flush();
    spans.add(EraseSpan(before.substring(i, end), erased: true));
    i = end;
    j += _someone.length;
  }
  flush();
  return spans;
}

/// [spans] cut to start at most [before] characters ahead of the first
/// erased span, with "…" where text was dropped.
List<EraseSpan> excerptAroundFirstErase(List<EraseSpan> spans,
    {int before = 60}) {
  var offset = 0;
  for (final span in spans) {
    if (span.erased) break;
    offset += span.text.length;
  }
  if (offset <= before) return spans;
  var skip = offset - before;
  final out = <EraseSpan>[const EraseSpan('…')];
  for (final span in spans) {
    if (skip >= span.text.length) {
      skip -= span.text.length;
      continue;
    }
    out.add(EraseSpan(span.text.substring(skip), erased: span.erased));
    skip = 0;
  }
  return out;
}
