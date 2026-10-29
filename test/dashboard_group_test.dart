// Dashboard sections. Supabase returns started_at in UTC; "today" is the
// user's local day. In the evening (west of UTC) the UTC date has already
// rolled over, and a notebook started minutes ago landed in "This week",
// below today's older notebooks.
//
// The rollover case only fails on a machine west of UTC; on a UTC machine
// the local and UTC days are the same and it passes either way.
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/screens/dashboard/dashboard_screen.dart';

void main() {
  final now = DateTime(2026, 10, 28, 23, 58); // local, late evening

  test('a notebook started this evening is Today after UTC rolls over', () {
    final startedAt = DateTime(2026, 10, 28, 23, 57).toUtc();
    expect(notebookGroup(startedAt, now), 'Today');
  });

  test('a notebook from earlier today is Today', () {
    expect(notebookGroup(DateTime(2026, 10, 28, 9).toUtc(), now), 'Today');
  });

  test('yesterday evening is This week, not Today', () {
    final startedAt = DateTime(2026, 10, 27, 23, 30).toUtc();
    expect(notebookGroup(startedAt, now), 'This week');
  });

  test('ten days ago is Earlier', () {
    expect(notebookGroup(DateTime(2026, 10, 18, 12).toUtc(), now), 'Earlier');
  });
}
