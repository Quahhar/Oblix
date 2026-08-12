/// Dart-side value types for the portable task engine.
///
/// Screens and repositories talk to these, never to the generated Flutter Rust
/// Bridge DTOs — the same boundary `crdt_types.dart` draws for notes. Records
/// are used wherever the shape is plain data; the two enums are named so a
/// `switch` over them stays exhaustive.
library;

/// A calendar date with no zone attached. Dart owns the conversion to and from
/// [DateTime]; the core only ever sees civil components.
typedef CivilDateValue = ({int year, int month, int day});

/// A wall-clock time with no zone attached.
typedef CivilTimeValue = ({int hour, int minute});

/// How often a task repeats.
enum CoreRecurrenceFreq { daily, weekly, monthly, yearly }

/// What the next occurrence is measured from — the fixed schedule, or the day
/// the task was actually finished.
enum CoreRecurrenceMode { schedule, completion }

/// A repetition rule. [byWeekday] holds Monday-relative indices (0 = Monday)
/// and only applies to [CoreRecurrenceFreq.weekly].
typedef RecurrenceRuleValue = ({
  CoreRecurrenceFreq freq,
  int interval,
  List<int> byWeekday,
  CoreRecurrenceMode mode,
});

/// Where a repeating task lands after it is ticked. A null [nextDue] means the
/// task does not repeat, or its rule could not advance.
typedef RecurrenceAdvanceValue = ({CivilDateValue? nextDue, bool keepsTime});

/// When a reminder should fire, in civil components.
typedef ReminderInstantValue = ({CivilDateValue date, CivilTimeValue time});

/// How a task list is ordered.
enum CoreTaskSort { smart, manual, priority, dueDate, alphabetical }

/// Which band of the list a row sits in.
enum CoreTaskSectionKind { overdue, focus, anytime, completed }

/// One task, reduced to what ordering and grouping need.
typedef TaskViewInputValue = ({
  String id,
  String title,
  String? parentId,
  int priority,
  CivilDateValue? due,
  CivilTimeValue? dueTime,
  bool isCompleted,
  CivilDateValue? completedOn,
  int sortOrder,
  int createdSeq,
});

/// A rendered row: [depth] is the indent level and the child counts drive the
/// "2/5" progress a parent shows.
typedef TaskRowValue = ({
  String id,
  int depth,
  int childTotal,
  int childDone,
  bool isOverdue,
});

typedef TaskSectionValue = ({
  CoreTaskSectionKind kind,
  String label,
  List<TaskRowValue> rows,
});

/// What the screen is currently showing.
typedef TaskViewContextValue = ({
  CivilDateValue today,
  CivilDateValue focus,
  CoreTaskSort sort,
  bool showCompleted,
  bool showAnytime,
});

/// One screenful of list, plus the counts the header shows.
typedef TaskViewPlanValue = ({
  List<TaskSectionValue> sections,
  int openCount,
  int overdueCount,
  int completedCount,
});

/// One cell of the month strip.
typedef CalendarDayValue = ({
  int day,
  int openCount,
  bool hasOverdue,
  bool hasUrgent,
  bool allDone,
});

/// A row whose manual rank moved.
typedef SortAssignmentValue = ({String id, int sortOrder});

/// The kind of thing a highlighted run of quick-add text turned out to be.
enum CoreQuickAddToken {
  date,
  time,
  priority,
  project,
  label,
  recurrence,
  reminder,
}

/// A recognized run of the quick-add input, in **UTF-16 code units** so the
/// offsets line up with Dart's `String` and `TextEditingValue`.
typedef QuickAddSpanValue = ({int start, int end, CoreQuickAddToken kind});

/// What the device knows and the parser cannot.
typedef QuickAddContextValue = ({
  CivilDateValue today,
  CivilTimeValue now,
  int todayWeekday,
  bool weekStartMonday,
  bool monthFirst,
});

/// Everything one typed line said.
typedef QuickAddParseValue = ({
  String title,
  int priority,
  String? project,
  List<String> labels,
  CivilDateValue? due,
  CivilTimeValue? dueTime,
  String? recurrence,
  int? reminderLeadMinutes,
  List<QuickAddSpanValue> spans,
});

/// Convert a local [DateTime] to the civil date the core works in.
CivilDateValue civilDateOf(DateTime local) => (
  year: local.year,
  month: local.month,
  day: local.day,
);

CivilTimeValue civilTimeOf(DateTime local) => (
  hour: local.hour,
  minute: local.minute,
);

/// Pin a civil date (and optional wall time) back to a local [DateTime].
///
/// This is the only place civil components become an instant, so the device's
/// zone and its DST discontinuities are applied exactly once.
DateTime localDateTimeOf(CivilDateValue date, [CivilTimeValue? time]) =>
    DateTime(date.year, date.month, date.day, time?.hour ?? 0, time?.minute ?? 0);
