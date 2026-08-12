/// The task engine, in Dart.
///
/// A behavioural mirror of `rust/src/api/tasks.rs`, kept for the two reasons
/// `RUST_CORE.md` gives for every mirror: it is the web and
/// pre-initialization path, and it is the oracle the differential tests
/// compare Rust against. Widget tests for the Tasks screen never call
/// `initializeOblixCore()`, so without this the list would not render at all.
///
/// `parseQuickAdd` is the deliberate exception — see the comment on it.
library;

import 'task_types.dart';

const List<String> _weekdayCodes = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
const List<String> _weekdayShort = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];
const List<String> _weekdayLong = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const List<String> _monthShort = [
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

/// Mirrors `MAX_ADVANCE_STEPS`: enough to clear a leap year at any frequency.
const int _maxAdvanceSteps = 400;

RecurrenceRuleValue _sanitizeRule(RecurrenceRuleValue rule) {
  final days = rule.freq == CoreRecurrenceFreq.weekly
      ? (rule.byWeekday.where((day) => day >= 0 && day < 7).toSet().toList()
          ..sort())
      : <int>[];
  return (
    freq: rule.freq,
    interval: rule.interval.clamp(1, 1000),
    byWeekday: List.unmodifiable(days),
    mode: rule.mode,
  );
}

String serializeRecurrence(RecurrenceRuleValue rule) {
  final clean = _sanitizeRule(rule);
  final freq = switch (clean.freq) {
    CoreRecurrenceFreq.daily => 'DAILY',
    CoreRecurrenceFreq.weekly => 'WEEKLY',
    CoreRecurrenceFreq.monthly => 'MONTHLY',
    CoreRecurrenceFreq.yearly => 'YEARLY',
  };
  final buffer = StringBuffer('FREQ=$freq;INTERVAL=${clean.interval}');
  if (clean.byWeekday.isNotEmpty) {
    final codes = clean.byWeekday.map((day) => _weekdayCodes[day]).join(',');
    buffer.write(';BYDAY=$codes');
  }
  if (clean.mode == CoreRecurrenceMode.completion) {
    buffer.write(';MODE=COMPLETION');
  }
  return buffer.toString();
}

RecurrenceRuleValue? parseRecurrence(String text) {
  CoreRecurrenceFreq? freq;
  var interval = 1;
  final byWeekday = <int>[];
  var mode = CoreRecurrenceMode.schedule;

  for (final part in text.split(';')) {
    final split = part.indexOf('=');
    if (split < 0) return null;
    final key = part.substring(0, split).trim().toUpperCase();
    final value = part.substring(split + 1).trim();
    switch (key) {
      case 'FREQ':
        freq = switch (value.toUpperCase()) {
          'DAILY' => CoreRecurrenceFreq.daily,
          'WEEKLY' => CoreRecurrenceFreq.weekly,
          'MONTHLY' => CoreRecurrenceFreq.monthly,
          'YEARLY' => CoreRecurrenceFreq.yearly,
          _ => null,
        };
        if (freq == null) return null;
      case 'INTERVAL':
        final parsed = int.tryParse(value);
        if (parsed == null) return null;
        interval = parsed;
      case 'BYDAY':
        for (final code in value.split(',')) {
          final trimmed = code.trim().toUpperCase();
          if (trimmed.isEmpty) continue;
          final index = _weekdayCodes.indexOf(trimmed);
          if (index < 0) return null;
          byWeekday.add(index);
        }
      case 'MODE':
        if (value.toUpperCase() == 'COMPLETION') {
          mode = CoreRecurrenceMode.completion;
        }
      default:
        break;
    }
  }
  if (freq == null) return null;
  return _sanitizeRule((
    freq: freq,
    interval: interval,
    byWeekday: byWeekday,
    mode: mode,
  ));
}

String describeRecurrence(RecurrenceRuleValue rule) {
  final clean = _sanitizeRule(rule);
  String every(String unit, String plural) =>
      clean.interval == 1 ? 'Every $unit' : 'Every ${clean.interval} $plural';

  String base;
  switch (clean.freq) {
    case CoreRecurrenceFreq.daily:
      base = every('day', 'days');
    case CoreRecurrenceFreq.yearly:
      base = every('year', 'years');
    case CoreRecurrenceFreq.monthly:
      base = every('month', 'months');
    case CoreRecurrenceFreq.weekly:
      if (clean.interval == 1 &&
          clean.byWeekday.length == 5 &&
          clean.byWeekday.every((day) => day < 5)) {
        return 'Every weekday';
      }
      if (clean.byWeekday.isEmpty) {
        base = every('week', 'weeks');
      } else if (clean.byWeekday.length == 1 && clean.interval == 1) {
        return 'Every ${_weekdayLong[clean.byWeekday.first]}';
      } else {
        final names = clean.byWeekday
            .map((day) => _weekdayShort[day])
            .join(', ');
        base = '${every('week', 'weeks')} on $names';
      }
  }
  return clean.mode == CoreRecurrenceMode.completion
      ? '$base after completion'
      : base;
}

/// Whether a civil triple names a real day.
///
/// `DateTime` normalizes overflow — February 30th silently becomes March 2nd —
/// so validity has to be checked rather than trusted. An impossible date reads
/// as undated, matching Chrono's `from_ymd_opt` returning `None`.
DateTime? _civilToDateTime(CivilDateValue? value) {
  if (value == null) return null;
  if (value.month < 1 || value.month > 12 || value.day < 1) return null;
  final resolved = DateTime(value.year, value.month, value.day);
  if (resolved.year != value.year ||
      resolved.month != value.month ||
      resolved.day != value.day) {
    return null;
  }
  return resolved;
}

CivilDateValue _dateTimeToCivil(DateTime value) =>
    (year: value.year, month: value.month, day: value.day);

int _daysInMonth(int year, int month) =>
    DateTime(month == 12 ? year + 1 : year, month == 12 ? 1 : month + 1, 1)
        .difference(DateTime(year, month, 1))
        .inDays;

DateTime _addMonths(DateTime date, int months) {
  final zeroBased = date.year * 12 + (date.month - 1) + months;
  final year = (zeroBased / 12).floor();
  final month = zeroBased - year * 12 + 1;
  final day = date.day.clamp(1, _daysInMonth(year, month));
  return DateTime(year, month, day);
}

DateTime _stepOnce(RecurrenceRuleValue rule, DateTime cursor) {
  switch (rule.freq) {
    case CoreRecurrenceFreq.daily:
      return cursor.add(Duration(days: rule.interval));
    case CoreRecurrenceFreq.monthly:
      return _addMonths(cursor, rule.interval);
    case CoreRecurrenceFreq.yearly:
      return _addMonths(cursor, rule.interval * 12);
    case CoreRecurrenceFreq.weekly:
      if (rule.byWeekday.isEmpty) {
        return cursor.add(Duration(days: rule.interval * 7));
      }
      final current = cursor.weekday - 1;
      for (final day in rule.byWeekday) {
        if (day > current) return cursor.add(Duration(days: day - current));
      }
      final monday = cursor.subtract(Duration(days: current));
      return monday.add(
        Duration(days: rule.interval * 7 + rule.byWeekday.first),
      );
  }
}

/// The next date a rule fires on, strictly after [from] and never before
/// [notBefore] — so ticking an overdue chore cannot leave it overdue.
CivilDateValue? nextOccurrence({
  required RecurrenceRuleValue rule,
  required CivilDateValue from,
  required CivilDateValue notBefore,
}) {
  final clean = _sanitizeRule(rule);
  final start = _civilToDateTime(from);
  if (start == null) return null;
  final floor = _civilToDateTime(notBefore) ?? start;
  var cursor = start;
  for (var step = 0; step < _maxAdvanceSteps; step++) {
    cursor = _stepOnce(clean, cursor);
    if (cursor.isAfter(start) && !cursor.isBefore(floor)) {
      return _dateTimeToCivil(cursor);
    }
  }
  return null;
}

RecurrenceAdvanceValue advanceOnCompletion({
  String? recurrence,
  CivilDateValue? due,
  required bool dueHasTime,
  required CivilDateValue completedOn,
}) {
  final rule = recurrence == null ? null : parseRecurrence(recurrence);
  if (rule == null) return (nextDue: null, keepsTime: false);
  final anchor = rule.mode == CoreRecurrenceMode.completion
      ? completedOn
      : (due ?? completedOn);
  return (
    nextDue: nextOccurrence(rule: rule, from: anchor, notBefore: completedOn),
    keepsTime: dueHasTime,
  );
}

ReminderInstantValue? reminderTime({
  required CivilDateValue due,
  CivilTimeValue? dueTime,
  required int leadMinutes,
  int allDayHour = 9,
  int allDayMinute = 0,
}) {
  final base = _civilToDateTime(due);
  if (base == null) return null;
  final hour = (dueTime?.hour ?? allDayHour).clamp(0, 23);
  final minute = (dueTime?.minute ?? allDayMinute).clamp(0, 59);
  final shifted = hour * 60 + minute - leadMinutes;
  final dayShift = (shifted / 1440).floor();
  final minuteOfDay = shifted - dayShift * 1440;
  return (
    date: _dateTimeToCivil(base.add(Duration(days: dayShift))),
    time: (hour: minuteOfDay ~/ 60, minute: minuteOfDay % 60),
  );
}

List<SortAssignmentValue> planReorder({
  required List<String> orderedIds,
  required List<SortAssignmentValue> current,
}) {
  const spacing = 1024;
  final changes = <SortAssignmentValue>[];
  for (var index = 0; index < orderedIds.length; index++) {
    final id = orderedIds[index];
    final target = (index + 1) * spacing;
    int? existing;
    for (final entry in current) {
      if (entry.id == id) {
        existing = entry.sortOrder;
        break;
      }
    }
    if (existing != target) changes.add((id: id, sortOrder: target));
  }
  return List.unmodifiable(changes);
}

List<CalendarDayValue> monthDensity({
  required List<TaskViewInputValue> tasks,
  required int year,
  required int month,
  required CivilDateValue today,
}) {
  if (month < 1 || month > 12) return const [];
  final length = _daysInMonth(year, month);
  final openCount = List<int>.filled(length, 0);
  final hasOverdue = List<bool>.filled(length, false);
  final hasUrgent = List<bool>.filled(length, false);
  final completed = List<bool>.filled(length, false);
  final todayDate = _civilToDateTime(today);

  for (final task in tasks) {
    final due = task.due;
    if (due == null) continue;
    if (due.year != year || due.month != month) continue;
    if (due.day < 1 || due.day > length) continue;
    final slot = due.day - 1;
    if (task.isCompleted) {
      completed[slot] = true;
      continue;
    }
    openCount[slot]++;
    if (task.priority >= 3) hasUrgent[slot] = true;
    final dueDate = _civilToDateTime(due);
    if (dueDate != null && todayDate != null && dueDate.isBefore(todayDate)) {
      hasOverdue[slot] = true;
    }
  }

  return List.unmodifiable([
    for (var slot = 0; slot < length; slot++)
      (
        day: slot + 1,
        openCount: openCount[slot],
        hasOverdue: hasOverdue[slot],
        hasUrgent: hasUrgent[slot],
        allDone: openCount[slot] == 0 && completed[slot],
      ),
  ]);
}

TaskViewPlanValue planTaskView({
  required List<TaskViewInputValue> tasks,
  required TaskViewContextValue context,
}) {
  final today = _civilToDateTime(context.today);
  final focus = _civilToDateTime(context.focus);
  final focusIsToday = today != null && focus != null && today == focus;

  final overdue = <TaskViewInputValue>[];
  final onFocus = <TaskViewInputValue>[];
  final anytime = <TaskViewInputValue>[];
  final done = <TaskViewInputValue>[];

  for (final task in tasks) {
    final due = _civilToDateTime(task.due);
    if (task.isCompleted) {
      // A finished task belongs to the day it was finished, so today's list
      // shows today's wins and does not accumulate history.
      final completedOn = _civilToDateTime(task.completedOn);
      if (context.showCompleted &&
          completedOn != null &&
          completedOn == focus) {
        done.add(task);
      }
      continue;
    }
    if (due == null) {
      // An unreadable due date lands here too: the task is real and must stay
      // reachable rather than vanish from every list.
      if (context.showAnytime && focusIsToday) anytime.add(task);
      continue;
    }
    if (today != null &&
        focus != null &&
        due.isBefore(today) &&
        focus == today) {
      overdue.add(task);
    } else if (focus != null && due == focus) {
      onFocus.add(task);
    }
  }

  final sections = <TaskSectionValue>[];
  void push(
    CoreTaskSectionKind kind,
    String label,
    List<TaskViewInputValue> bucket,
  ) {
    if (bucket.isEmpty) return;
    sections.add((
      kind: kind,
      label: label,
      rows: _arrange(bucket, tasks, context.sort, today),
    ));
  }

  push(CoreTaskSectionKind.overdue, 'OVERDUE', overdue);
  push(
    CoreTaskSectionKind.focus,
    _focusLabel(context.focus, context.today, focusIsToday),
    onFocus,
  );
  push(CoreTaskSectionKind.anytime, 'ANYTIME', anytime);
  push(CoreTaskSectionKind.completed, 'COMPLETED', done);

  return (
    sections: List.unmodifiable(sections),
    openCount: overdue.length + onFocus.length,
    overdueCount: overdue.length,
    completedCount: done.length,
  );
}

String _focusLabel(
  CivilDateValue focus,
  CivilDateValue today,
  bool focusIsToday,
) {
  if (focusIsToday) return 'TODAY';
  final focusDate = _civilToDateTime(focus);
  final todayDate = _civilToDateTime(today);
  if (focusDate == null || todayDate == null) return 'SCHEDULED';
  final days = focusDate.difference(todayDate).inDays;
  if (days == 1) return 'TOMORROW';
  if (days == -1) return 'YESTERDAY';
  if (days >= 2 && days < 7) {
    return _weekdayLong[focusDate.weekday - 1].toUpperCase();
  }
  final month = _monthShort[focusDate.month - 1].toUpperCase();
  final label = '$month ${focusDate.day}';
  return focusDate.year == todayDate.year ? label : '$label, ${focusDate.year}';
}

/// Sort one bucket and thread its subtasks in underneath their parents. A
/// subtask whose parent is filtered out is promoted rather than hidden.
List<TaskRowValue> _arrange(
  List<TaskViewInputValue> bucket,
  List<TaskViewInputValue> all,
  CoreTaskSort sort,
  DateTime? today,
) {
  final visible = bucket.map((task) => task.id).toSet();
  final roots = bucket
      .where(
        (task) => task.parentId == null || !visible.contains(task.parentId),
      )
      .toList();
  _sortBucket(roots, sort, today);

  final rows = <TaskRowValue>[];
  void emit(TaskViewInputValue task, int depth) {
    var total = 0;
    var completed = 0;
    for (final candidate in all) {
      if (candidate.parentId == task.id) {
        total++;
        if (candidate.isCompleted) completed++;
      }
    }
    final due = _civilToDateTime(task.due);
    rows.add((
      id: task.id,
      depth: depth,
      childTotal: total,
      childDone: completed,
      isOverdue:
          due != null &&
          today != null &&
          !task.isCompleted &&
          due.isBefore(today),
    ));
    final children = bucket
        .where((candidate) => candidate.parentId == task.id)
        .toList();
    _sortBucket(children, sort, today);
    // Two levels of indent is as deep as a phone row stays readable.
    final childDepth = depth + 1 > 2 ? 2 : depth + 1;
    for (final child in children) {
      emit(child, childDepth);
    }
  }

  for (final root in roots) {
    emit(root, 0);
  }
  return List.unmodifiable(rows);
}

int _rankPriority(TaskViewInputValue task) => -task.priority.clamp(0, 3);

int _rankClock(TaskViewInputValue task) {
  final time = task.dueTime;
  if (time == null) return 0x7fffffff;
  return time.hour.clamp(0, 23) * 60 + time.minute.clamp(0, 59);
}

int _rankLateness(TaskViewInputValue task, DateTime? today) {
  final due = _civilToDateTime(task.due);
  if (due == null || today == null) return 0;
  final late = today.difference(due).inDays;
  return late > 0 ? -late : 0;
}

void _sortBucket(
  List<TaskViewInputValue> bucket,
  CoreTaskSort sort,
  DateTime? today,
) {
  int chain(List<int Function()> comparisons) {
    for (final comparison in comparisons) {
      final result = comparison();
      if (result != 0) return result;
    }
    return 0;
  }

  bucket.sort(
    (left, right) => switch (sort) {
      CoreTaskSort.manual => chain([
        () => left.sortOrder.compareTo(right.sortOrder),
        () => left.createdSeq.compareTo(right.createdSeq),
      ]),
      CoreTaskSort.alphabetical => chain([
        () => left.title.toLowerCase().compareTo(right.title.toLowerCase()),
        () => left.createdSeq.compareTo(right.createdSeq),
      ]),
      CoreTaskSort.priority => chain([
        () => _rankPriority(left).compareTo(_rankPriority(right)),
        () => _rankClock(left).compareTo(_rankClock(right)),
        () => left.sortOrder.compareTo(right.sortOrder),
        () => left.createdSeq.compareTo(right.createdSeq),
      ]),
      CoreTaskSort.dueDate => chain([
        () => _rankClock(left).compareTo(_rankClock(right)),
        () => _rankPriority(left).compareTo(_rankPriority(right)),
        () => left.sortOrder.compareTo(right.sortOrder),
        () => left.createdSeq.compareTo(right.createdSeq),
      ]),
      // Smart: how late it already is, then how much it matters, then when it
      // is due, then the arrangement the user chose by hand.
      CoreTaskSort.smart => chain([
        () => _rankLateness(left, today).compareTo(_rankLateness(right, today)),
        () => _rankPriority(left).compareTo(_rankPriority(right)),
        () => _rankClock(left).compareTo(_rankClock(right)),
        () => left.sortOrder.compareTo(right.sortOrder),
        () => left.createdSeq.compareTo(right.createdSeq),
      ]),
    },
  );
}

/// Quick add, without a grammar.
///
/// The one part of the engine with no Dart mirror. A second natural-language
/// date parser would drift from the first invisibly, and the failure it
/// produces — a task quietly filed on the wrong day — is worse than not
/// parsing at all. Before the native core is ready the line becomes the title
/// verbatim, which is exactly what the old sheet did.
QuickAddParseValue parseQuickAdd({
  required String text,
  required QuickAddContextValue context,
}) => (
  title: text.trim(),
  priority: 0,
  project: null,
  labels: const <String>[],
  due: null,
  dueTime: null,
  recurrence: null,
  reminderLeadMinutes: null,
  spans: const <QuickAddSpanValue>[],
);
