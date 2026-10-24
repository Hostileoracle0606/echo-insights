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

String relativeTime(DateTime date, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(date);

  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';

  return '${_months[date.month - 1]} ${date.day}';
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// When something was said, for Lumen to say back: "Fri, Oct 16 (last
/// week)". The hint counts calendar days, Monday-start weeks and calendar
/// months in local time, the way people talk about the past; the year is
/// added only once it differs from now's.
String spokenWhen(DateTime at, {DateTime? now}) {
  final local = at.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();
  // Date-only UTC values, so DST shifts never change a day count.
  final day = DateTime.utc(local.year, local.month, local.day);
  final today = DateTime.utc(reference.year, reference.month, reference.day);
  final days = today.difference(day).inDays;
  final weeks = today
          .subtract(Duration(days: today.weekday - 1))
          .difference(day.subtract(Duration(days: day.weekday - 1)))
          .inDays ~/
      7;
  final months =
      (reference.year * 12 + reference.month) - (local.year * 12 + local.month);

  final String hint;
  if (days <= 0) {
    hint = 'today';
  } else if (days == 1) {
    hint = 'yesterday';
  } else if (weeks == 0) {
    hint = 'this week';
  } else if (weeks == 1) {
    hint = 'last week';
  } else if (weeks <= 4) {
    hint = '$weeks weeks ago';
  } else if (months <= 1) {
    hint = 'last month';
  } else if (months < 12) {
    hint = '$months months ago';
  } else {
    hint = 'over a year ago';
  }

  final year = local.year == reference.year ? '' : ', ${local.year}';
  return '${_weekdays[local.weekday - 1]}, '
      '${_months[local.month - 1]} ${local.day}$year ($hint)';
}
