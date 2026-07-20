/// Tiny date/time formatters for the Paper UI (no intl dependency — the
/// design's labels are English-only anyway).
abstract final class Formats {
  static const _weekdays = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];
  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ];

  /// "FRIDAY, JULY 11" — the home header eyebrow.
  static String dateEyebrow(DateTime d) =>
      '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}'
          .toUpperCase();

  /// "2:41 PM"
  static String time(DateTime d) {
    final local = d.toLocal();
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  /// "Just now" / "5h ago" / "2d ago" / "Jun 28"
  static String relative(DateTime d, {DateTime? now}) {
    final ref = (now ?? DateTime.now()).toUtc();
    final diff = ref.difference(d.toUtc());
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final local = d.toLocal();
    final label = '${_months[local.month - 1].substring(0, 3)} ${local.day}';
    return local.year == ref.toLocal().year ? label : '$label, ${local.year}';
  }

  /// Day-group heading: TODAY / YESTERDAY / a weekday within the last week /
  /// "JULY 8" (with year when older).
  static String dayGroup(DateTime d, {DateTime? now}) {
    final ref = (now ?? DateTime.now()).toLocal();
    final local = d.toLocal();
    final today = DateTime(ref.year, ref.month, ref.day);
    final day = DateTime(local.year, local.month, local.day);
    final days = today.difference(day).inDays;
    if (days <= 0) return 'TODAY';
    if (days == 1) return 'YESTERDAY';
    if (days < 7) return _weekdays[day.weekday - 1].toUpperCase();
    final label = '${_months[day.month - 1]} ${day.day}'.toUpperCase();
    return day.year == ref.year ? label : '$label, ${day.year}';
  }

  /// Task-group heading relative to today: OVERDUE handled by the caller;
  /// this returns TODAY / TOMORROW / weekday within a week / "JULY 8".
  static String dueGroup(DateTime d, {DateTime? now}) {
    final ref = (now ?? DateTime.now()).toLocal();
    final local = d.toLocal();
    final today = DateTime(ref.year, ref.month, ref.day);
    final day = DateTime(local.year, local.month, local.day);
    final days = day.difference(today).inDays;
    if (days <= 0) return 'TODAY';
    if (days == 1) return 'TOMORROW';
    if (days < 7) return _weekdays[day.weekday - 1].toUpperCase();
    final label = '${_months[day.month - 1]} ${day.day}'.toUpperCase();
    return day.year == ref.year ? label : '$label, ${day.year}';
  }

  /// "612 words"
  static String wordCount(String text) {
    final n = RegExp(r'\S+').allMatches(text).length;
    return '$n ${n == 1 ? 'word' : 'words'}';
  }
}
