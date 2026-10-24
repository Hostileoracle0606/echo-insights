// Dates on the closing card (LM-16), in English like the rest of the copy.
// Callers pass local times; these only format.

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Fri, Oct 23".
String shortDay(DateTime day) =>
    '${_weekdays[day.weekday - 1].substring(0, 3)}, ${monthDay(day)}';

/// "Oct 30".
String monthDay(DateTime day) => '${_months[day.month - 1]} ${day.day}';

/// When an open item is due, said from [from]'s day: "ask tomorrow",
/// "ask Tuesday", "ask next Friday", or "ask Nov 6" two weeks or more out
/// (and for anything already past).
String askWhen(DateTime from, DateTime due) {
  final days = DateTime.utc(due.year, due.month, due.day)
      .difference(DateTime.utc(from.year, from.month, from.day))
      .inDays;
  final weekday = _weekdays[due.weekday - 1];
  return switch (days) {
    0 => 'ask today',
    1 => 'ask tomorrow',
    >= 2 && <= 6 => 'ask $weekday',
    >= 7 && <= 13 => 'ask next $weekday',
    _ => 'ask ${monthDay(due)}',
  };
}
