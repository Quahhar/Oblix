import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/db/app_database.dart';
import 'package:oblix/core/native/oblix_core.dart';
import 'package:oblix/data/models/task.dart';
import 'package:oblix/data/repositories/task_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The task engine and the repository built on it.
///
/// These run against the Dart oracle rather than the native core, which is the
/// point: the oracle is what widget tests and the web build use, so its
/// behaviour has to be pinned independently. `rust_codecs_and_mutations_test`
/// is what proves Rust agrees with it.
void main() {
  setUpAll(sqfliteFfiInit);

  CivilDateValue date(int year, int month, int day) =>
      (year: year, month: month, day: day);

  group('recurrence', () {
    test('round-trips through its stored form', () {
      const rule = (
        freq: CoreRecurrenceFreq.weekly,
        interval: 2,
        byWeekday: [0, 3],
        mode: CoreRecurrenceMode.completion,
      );
      final text = serializeRecurrence(rule);
      expect(text, 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH;MODE=COMPLETION');

      // Compared field by field: the record holds a List, and Dart record
      // equality compares that by identity, so two structurally identical
      // rules are never `==`.
      final parsed = parseRecurrence(text);
      expect(parsed, isNotNull);
      expect(parsed!.freq, rule.freq);
      expect(parsed.interval, rule.interval);
      expect(parsed.byWeekday, rule.byWeekday);
      expect(parsed.mode, rule.mode);
    });

    test('a malformed rule reads as no repetition', () {
      expect(parseRecurrence('FREQ=FORTNIGHTLY'), isNull);
      expect(parseRecurrence('nonsense'), isNull);
      expect(parseRecurrence(''), isNull);
    });

    test('monthly clamps instead of rolling into the next month', () {
      // Jan 31 plus a month is the last day of February, never March 3rd.
      expect(
        nextOccurrence(
          rule: (
            freq: CoreRecurrenceFreq.monthly,
            interval: 1,
            byWeekday: const [],
            mode: CoreRecurrenceMode.schedule,
          ),
          from: date(2026, 1, 31),
          notBefore: date(2026, 1, 31),
        ),
        date(2026, 2, 28),
      );
    });

    test('completing a late bill catches up past today', () {
      // Rent due in May, ticked in August: the next one is September, so the
      // task does not reappear already overdue.
      final advance = advanceOnCompletion(
        recurrence: 'FREQ=MONTHLY;INTERVAL=1',
        due: date(2026, 5, 1),
        dueHasTime: false,
        completedOn: date(2026, 8, 10),
      );
      expect(advance.nextDue, date(2026, 9, 1));
    });

    test('completion mode measures from the day the work was done', () {
      final advance = advanceOnCompletion(
        recurrence: 'FREQ=DAILY;INTERVAL=3;MODE=COMPLETION',
        due: date(2026, 8, 4),
        dueHasTime: true,
        completedOn: date(2026, 8, 10),
      );
      expect(advance.nextDue, date(2026, 8, 13));
      expect(advance.keepsTime, isTrue);
    });

    test('describes itself in English', () {
      expect(
        describeRecurrence((
          freq: CoreRecurrenceFreq.weekly,
          interval: 1,
          byWeekday: const [0, 1, 2, 3, 4],
          mode: CoreRecurrenceMode.schedule,
        )),
        'Every weekday',
      );
      expect(
        describeRecurrence((
          freq: CoreRecurrenceFreq.weekly,
          interval: 2,
          byWeekday: const [0, 3],
          mode: CoreRecurrenceMode.schedule,
        )),
        'Every 2 weeks on Mon, Thu',
      );
    });
  });

  group('view planning', () {
    TaskViewInputValue task(
      String id, {
      CivilDateValue? due,
      CivilTimeValue? dueTime,
      int priority = 0,
      String? parentId,
      bool completed = false,
      CivilDateValue? completedOn,
    }) => (
      id: id,
      title: id,
      parentId: parentId,
      priority: priority,
      due: due,
      dueTime: dueTime,
      isCompleted: completed,
      completedOn: completedOn,
      sortOrder: 0,
      createdSeq: 0,
    );

    TaskViewContextValue context({CivilDateValue? focus}) => (
      today: date(2026, 8, 10),
      focus: focus ?? date(2026, 8, 10),
      sort: CoreTaskSort.smart,
      showCompleted: true,
      showAnytime: true,
    );

    test('today leads with overdue, then today, then the backlog', () {
      final plan = planTaskView(
        tasks: [
          task('late', due: date(2026, 8, 4)),
          task('now', due: date(2026, 8, 10)),
          task('someday'),
          task('future', due: date(2026, 9, 1)),
        ],
        context: context(),
      );
      expect(
        plan.sections.map((section) => section.label),
        ['OVERDUE', 'TODAY', 'ANYTIME'],
      );
      expect(plan.overdueCount, 1);
      expect(plan.openCount, 2);
    });

    test('a future day hides overdue work and the undated backlog', () {
      final plan = planTaskView(
        tasks: [
          task('late', due: date(2026, 8, 4)),
          task('someday'),
          task('then', due: date(2026, 8, 11)),
        ],
        context: context(focus: date(2026, 8, 11)),
      );
      expect(plan.sections.map((section) => section.label), ['TOMORROW']);
    });

    test('the longest overdue leads, then the most urgent', () {
      final plan = planTaskView(
        tasks: [
          task('slightly-late', due: date(2026, 8, 9), priority: 3),
          task('very-late', due: date(2026, 8, 1)),
        ],
        context: context(),
      );
      expect(
        plan.sections.first.rows.map((row) => row.id),
        ['very-late', 'slightly-late'],
      );
    });

    test('subtasks indent under a visible parent and roll progress up', () {
      final plan = planTaskView(
        tasks: [
          task('child', due: date(2026, 8, 10), parentId: 'parent'),
          task('parent', due: date(2026, 8, 10)),
          task(
            'done-child',
            due: date(2026, 8, 10),
            parentId: 'parent',
            completed: true,
            completedOn: date(2026, 8, 9),
          ),
        ],
        context: context(),
      );
      final rows = plan.sections.first.rows;
      expect(rows[0].id, 'parent');
      expect(rows[0].depth, 0);
      // The child finished yesterday is off screen but still counted.
      expect(rows[0].childTotal, 2);
      expect(rows[0].childDone, 1);
      expect(rows[1].id, 'child');
      expect(rows[1].depth, 1);
    });

    test('an orphaned subtask is promoted rather than hidden', () {
      // Parent next week, child today: the child still has to appear.
      final plan = planTaskView(
        tasks: [
          task('parent', due: date(2026, 8, 20)),
          task('child', due: date(2026, 8, 10), parentId: 'parent'),
        ],
        context: context(),
      );
      expect(plan.sections.first.rows.single.id, 'child');
      expect(plan.sections.first.rows.single.depth, 0);
    });

    test('a task with an unreadable due date is shown, not dropped', () {
      final plan = planTaskView(
        tasks: [task('bad', due: date(2026, 2, 30))],
        context: context(),
      );
      expect(plan.sections.single.kind, CoreTaskSectionKind.anytime);
      expect(plan.sections.single.rows.single.id, 'bad');
    });

    test('month density counts open work and marks cleared days', () {
      final days = monthDensity(
        tasks: [
          task('late', due: date(2026, 8, 4)),
          task('urgent', due: date(2026, 8, 12), priority: 3),
          task(
            'cleared',
            due: date(2026, 8, 3),
            completed: true,
            completedOn: date(2026, 8, 3),
          ),
        ],
        year: 2026,
        month: 8,
        today: date(2026, 8, 10),
      );
      expect(days.length, 31);
      expect(days[3].hasOverdue, isTrue);
      expect(days[11].hasUrgent, isTrue);
      expect(days[2].allDone, isTrue);
    });
  });

  group('reminders and reordering', () {
    test('a lead time can cross back over midnight', () {
      final fired = reminderTime(
        due: date(2026, 8, 10),
        dueTime: (hour: 0, minute: 30),
        leadMinutes: 60,
      );
      expect(fired?.date, date(2026, 8, 9));
      expect(fired?.time, (hour: 23, minute: 30));
    });

    test('reorder only reports the rows that moved', () {
      const current = [
        (id: 'a', sortOrder: 1024),
        (id: 'b', sortOrder: 2048),
        (id: 'c', sortOrder: 3072),
      ];
      expect(
        planReorder(orderedIds: const ['a', 'b', 'c'], current: current),
        isEmpty,
      );
      final moved = planReorder(
        orderedIds: const ['a', 'c', 'b'],
        current: current,
      );
      expect(moved.map((change) => change.id), ['c', 'b']);
      expect(moved.first.sortOrder, 2048);
    });
  });

  group('repository', () {
    late Directory directory;
    late AppDatabase db;
    late TaskRepository tasks;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('oblix-tasks-');
      db = AppDatabase.ephemeral(
        dbFactory: databaseFactoryFfi,
        path: '${directory.path}${Platform.pathSeparator}oblix.db',
      );
      await db.database;
      tasks = TaskRepository(appDb: db);
    });

    tearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });

    test('a repeating task rolls forward instead of being retired', () async {
      final due = DateTime.now().toUtc().add(const Duration(days: 1));
      final task = await tasks.createTask(
        title: 'Water the plants',
        dueDate: due,
        recurrence: 'FREQ=DAILY;INTERVAL=3',
      );

      final rolled = await tasks.setCompleted(task.id, true);
      expect(
        rolled.isCompleted,
        isFalse,
        reason: 'a recurring chore that vanishes when ticked is the bug',
      );
      expect(rolled.dueDate!.isAfter(due), isTrue);
      expect(rolled.recurrence, 'FREQ=DAILY;INTERVAL=3');
    });

    test('a one-off task still completes normally', () async {
      final task = await tasks.createTask(title: 'Post the letter');
      final done = await tasks.setCompleted(task.id, true);
      expect(done.isCompleted, isTrue);
      expect(done.completedAt, isNotNull);
    });

    test('completing a parent completes its subtasks', () async {
      final parent = await tasks.createTask(title: 'Plan the trip');
      final child = await tasks.createTask(
        title: 'Book the flight',
        parentId: parent.id,
      );

      await tasks.setCompleted(parent.id, true);
      expect((await tasks.getTask(child.id))!.isCompleted, isTrue);
    });

    test('deleting a parent takes its subtasks with it', () async {
      final parent = await tasks.createTask(title: 'Plan the trip');
      final child = await tasks.createTask(
        title: 'Book the hotel',
        parentId: parent.id,
      );

      await tasks.deleteTask(parent.id);
      expect((await tasks.getTask(child.id))!.isDeleted, isTrue);
    });

    test('a reminder lead is turned into an absolute firing time', () async {
      // Truncated to the minute: reminders are computed from civil components,
      // which carry no seconds, so a due date with seconds would make the
      // difference 30 minutes plus whatever second it happened to be.
      final base = DateTime.now().toUtc().add(const Duration(days: 2));
      final due = DateTime.utc(
        base.year,
        base.month,
        base.day,
        base.hour,
        base.minute,
      );
      final task = await tasks.createTask(
        title: 'Call the dentist',
        dueDate: due,
        dueHasTime: true,
        reminderLeadMinutes: 30,
      );
      expect(task.reminderAt, isNotNull);
      expect(
        due.difference(task.reminderAt!),
        const Duration(minutes: 30),
      );

      // Moving the date has to move the alarm with it, or the reminder fires
      // for an occurrence that has already gone.
      final moved = await tasks.updateTask(
        task.id,
        dueDate: due.add(const Duration(days: 1)),
        dueHasTime: true,
      );
      expect(moved.reminderAt!.isAfter(task.reminderAt!), isTrue);
    });

    test('labels are normalized on the way in', () async {
      final task = await tasks.createTask(
        title: 'Email the board',
        labels: const ['  Email  ', 'email', '', 'Calls'],
      );
      expect(task.labels, ['Email', 'Calls']);
    });

    test('priority survives a round trip through SQLite', () async {
      final task = await tasks.createTask(
        title: 'Ship it',
        priority: TaskPriority.urgent,
      );
      expect((await tasks.getTask(task.id))!.priority, TaskPriority.urgent);
    });

    test('quick add falls back to the raw line without the native core', () {
      // The Dart oracle deliberately has no grammar; it must still produce a
      // usable task rather than throwing.
      final parsed = tasks.previewQuickAdd('pay rent tomorrow 5pm p1');
      expect(parsed.title, 'pay rent tomorrow 5pm p1');
      expect(parsed.due, isNull);
      expect(parsed.spans, isEmpty);
    });

    test('the working set carries open tasks and recent completions', () async {
      final open = await tasks.createTask(title: 'Open');
      final done = await tasks.createTask(title: 'Done');
      await tasks.setCompleted(done.id, true);

      final working = await tasks.loadWorkingSet();
      expect(working.map((task) => task.id), containsAll([open.id, done.id]));
    });
  });
}
