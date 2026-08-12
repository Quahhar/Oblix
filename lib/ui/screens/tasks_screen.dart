import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/native/oblix_core.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../sheets/task_detail_sheet.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';
import '../widgets/quick_add_field.dart';
import '../widgets/task_calendar.dart';
import '../widgets/task_row.dart';

/// The Tasks tab.
///
/// One list, focused on a single day — today, until you pick another. The date
/// header doubles as the calendar, and the only control that creates anything
/// is the line at the bottom. Everything else the screen knows how to do —
/// overdue first, urgent above calm, subtasks under their parent, repeating
/// chores rolling forward — is decided by the portable core and simply
/// rendered here.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final _tasks = TaskRepository();
  final _quickAdd = QuickAddController();

  StreamSubscription<void>? _changes;

  /// The whole working set. The core turns it into a screenful.
  List<Task> _all = const [];
  Map<String, Task> _byId = const {};

  TaskViewPlanValue? _plan;
  List<CalendarDayValue> _density = const [];

  DateTime _today = _startOfDay(DateTime.now());
  DateTime _focus = _startOfDay(DateTime.now());
  DateTime _visibleMonth = _firstOfMonth(DateTime.now());
  CalendarMode _calendar = CalendarMode.collapsed;
  CoreTaskSort _sort = CoreTaskSort.smart;
  bool _showCompleted = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _changes = _tasks.onChanged.listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _quickAdd.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final all = await _tasks.loadWorkingSet();
    if (!mounted) return;
    setState(() {
      _all = all;
      _byId = {for (final task in all) task.id: task};
      // Recomputed on every load so a session left open overnight rolls to the
      // new day instead of insisting it is still yesterday.
      _today = _startOfDay(DateTime.now());
      _loading = false;
      _replan();
    });
  }

  /// Ask the core what to show. Cheap enough to run on every rebuild trigger.
  void _replan() {
    final inputs = [for (final task in _all) _toViewInput(task)];
    _plan = planTaskView(
      tasks: inputs,
      context: (
        today: civilDateOf(_today),
        focus: civilDateOf(_focus),
        sort: _sort,
        showCompleted: _showCompleted,
        showAnytime: true,
      ),
    );
    _density = monthDensity(
      tasks: inputs,
      year: _visibleMonth.year,
      month: _visibleMonth.month,
      today: civilDateOf(_today),
    );
  }

  TaskViewInputValue _toViewInput(Task task) {
    final due = task.dueDate?.toLocal();
    final completed = task.completedAt?.toLocal();
    return (
      id: task.id,
      title: task.title,
      parentId: task.parentId,
      priority: task.priority.value,
      due: due == null ? null : civilDateOf(due),
      dueTime: due == null || !task.dueHasTime ? null : civilTimeOf(due),
      isCompleted: task.isCompleted,
      completedOn: completed == null ? null : civilDateOf(completed),
      sortOrder: task.sortOrder,
      createdSeq: task.createdAt.microsecondsSinceEpoch,
    );
  }

  void _setFocus(DateTime day) {
    setState(() {
      _focus = day;
      if (day.year != _visibleMonth.year || day.month != _visibleMonth.month) {
        _visibleMonth = _firstOfMonth(day);
      }
      _replan();
    });
  }

  Future<void> _add(String text) async {
    final parsed = _tasks.previewQuickAdd(text);
    final created = await _tasks.createFromQuickAdd(text);
    // A task typed while looking at Thursday belongs to Thursday — but only
    // when the line said nothing about a day itself. An explicit "tomorrow"
    // always beats the date that happens to be on screen.
    if (parsed.due == null && !_sameDay(_focus, _today)) {
      await _tasks.updateTask(created.id, dueDate: _focus.toUtc());
    }
  }

  Future<void> _toggle(Task task) async {
    final wasRepeating = task.repeats;
    await _tasks.setCompleted(task.id, !task.isCompleted);
    if (!mounted) return;
    if (wasRepeating && !task.isCompleted) {
      _snack('Moved to the next occurrence');
    }
  }

  Future<void> _swipe(Task task, TaskSwipe action) async {
    switch (action) {
      case TaskSwipe.schedule:
        await _quickSchedule(task);
      case TaskSwipe.delete:
        await _deleteWithUndo(task);
    }
  }

  /// One tap to push a task to a sensible day. The full picker is in the
  /// detail sheet; this covers the case that actually happens — "not today".
  Future<void> _quickSchedule(Task task) async {
    final choice = await showModalBottomSheet<DateTime?>(
      context: context,
      builder: (context) {
        final c = OblixColors.of(context);
        final today = _startOfDay(DateTime.now());
        final options = <(IconData, String, DateTime?)>[
          (Icons.wb_sunny_outlined, 'Today', today),
          (
            Icons.arrow_forward,
            'Tomorrow',
            today.add(const Duration(days: 1)),
          ),
          (
            Icons.next_week_outlined,
            'Next week',
            today.add(const Duration(days: 7)),
          ),
          (Icons.block, 'No date', null),
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetGrabHandle(),
              SectionEyebrow(
                'Move to',
                padding: const EdgeInsets.fromLTRB(22, 2, 22, 4),
              ),
              for (final option in options)
                ListTile(
                  leading: Icon(option.$1, color: c.inkSecondary, size: 20),
                  title: Text(option.$2, style: OblixType.ui(c, size: 15)),
                  onTap: () => Navigator.pop(context, option.$3),
                ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    // A null choice is ambiguous — the sheet was dismissed, or "No date" was
    // chosen — so the list is asked to rebuild either way and the write only
    // happens when something was actually picked.
    if (choice != null) {
      await _tasks.updateTask(task.id, dueDate: choice.toUtc(), dueHasTime: false);
    }
    setState(() {});
  }

  Future<void> _deleteWithUndo(Task task) async {
    final messenger = ScaffoldMessenger.of(context);
    await _tasks.deleteTask(task.id);
    if (!mounted) return;
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Deleted "${task.title}"'),
        action: SnackBarAction(
          label: 'Undo',
          // Recreating rather than un-tombstoning keeps the outbox honest:
          // the delete has already been queued for every other device.
          onPressed: () => _tasks.createTask(
            title: task.title,
            description: task.description,
            dueDate: task.dueDate,
            dueHasTime: task.dueHasTime,
            priority: task.priority,
            labels: task.labels,
            recurrence: task.recurrence,
            reminderLeadMinutes: task.reminderLeadMinutes,
            noteId: task.noteId,
            notebookId: task.notebookId,
            parentId: task.parentId,
          ),
        ),
      ),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openSortMenu() async {
    final choice = await showModalBottomSheet<CoreTaskSort>(
      context: context,
      builder: (context) {
        final c = OblixColors.of(context);
        const labels = {
          CoreTaskSort.smart: 'Smart',
          CoreTaskSort.dueDate: 'By time',
          CoreTaskSort.priority: 'By priority',
          CoreTaskSort.manual: 'My order',
          CoreTaskSort.alphabetical: 'A to Z',
        };
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetGrabHandle(),
              SectionEyebrow(
                'Sort',
                padding: const EdgeInsets.fromLTRB(22, 2, 22, 4),
              ),
              for (final entry in labels.entries)
                ListTile(
                  title: Text(entry.value, style: OblixType.ui(c, size: 15)),
                  trailing: entry.key == _sort
                      ? Icon(Icons.check, size: 20, color: c.accent)
                      : null,
                  onTap: () => Navigator.pop(context, entry.key),
                ),
              SwitchListTile(
                value: _showCompleted,
                onChanged: (value) {
                  Navigator.pop(context);
                  setState(() {
                    _showCompleted = value;
                    _replan();
                  });
                },
                title: Text(
                  'Show completed',
                  style: OblixType.ui(c, size: 15),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
    if (choice == null) return;
    setState(() {
      _sort = choice;
      _replan();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final plan = _plan;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TaskCalendar(
                  mode: _calendar,
                  today: _today,
                  focus: _focus,
                  visibleMonth: _visibleMonth,
                  density: _density,
                  openCount: plan?.openCount ?? 0,
                  overdueCount: plan?.overdueCount ?? 0,
                  onModeChanged: (mode) => setState(() => _calendar = mode),
                  onFocusChanged: _setFocus,
                  onMonthChanged: (month) => setState(() {
                    _visibleMonth = month;
                    _replan();
                  }),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12, top: 20),
                child: CircleIconButton(
                  Icons.tune,
                  tooltip: 'Sort and filter',
                  onTap: _openSortMenu,
                ),
              ),
            ],
          ),
          Expanded(
            child: _loading
                ? const SizedBox.shrink()
                : RefreshIndicator(
                    onRefresh: _reload,
                    child: _list(c, plan),
                  ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              14,
              8,
              14,
              // Clear the floating dock, and the keyboard when it is up.
              MediaQuery.viewInsetsOf(context).bottom > 0 ? 12 : 78,
            ),
            child: QuickAddField(
              controller: _quickAdd,
              parse: _tasks.previewQuickAdd,
              onSubmit: _add,
              hint: _sameDay(_focus, _today)
                  ? 'Add a task…'
                  : 'Add to ${_shortDay(_focus)}…',
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(OblixColors c, TaskViewPlanValue? plan) {
    if (plan == null || plan.sections.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [const SizedBox(height: 70), _empty(c)],
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 20),
      children: [
        for (final section in plan.sections) ...[
          SectionEyebrow(
            section.rows.length > 1
                ? '${section.label} · ${section.rows.length}'
                : section.label,
            color: switch (section.kind) {
              CoreTaskSectionKind.overdue => c.danger,
              CoreTaskSectionKind.focus => c.accentDeep,
              _ => c.inkMuted,
            },
            rule: true,
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 2),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _sort == CoreTaskSort.manual
                ? _reorderable(c, section)
                : Column(
                    children: [
                      for (var i = 0; i < section.rows.length; i++)
                        _row(c, section.rows[i], first: i == 0),
                    ],
                  ),
          ),
        ],
      ],
    );
  }

  /// Drag to arrange, but only under "My order".
  ///
  /// Offering a drag handle while the list is sorted by urgency would be a lie
  /// — the row would snap back the moment the core re-planned. Manual sort is
  /// the one mode where the stored rank is what you see.
  Widget _reorderable(OblixColors c, TaskSectionValue section) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: section.rows.length,
      onReorder: (oldIndex, newIndex) => _reorder(section, oldIndex, newIndex),
      itemBuilder: (context, index) {
        final row = section.rows[index];
        return ReorderableDelayedDragStartListener(
          key: ValueKey('reorder-${row.id}'),
          index: index,
          child: _row(c, row, first: index == 0),
        );
      },
    );
  }

  Future<void> _reorder(
    TaskSectionValue section,
    int oldIndex,
    int newIndex,
  ) async {
    // ReorderableListView reports the insertion point in the pre-removal list.
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final ids = section.rows.map((row) => row.id).toList();
    final moved = ids.removeAt(oldIndex);
    ids.insert(target, moved);
    // Optimistic: the drag has already animated, so re-plan from the new order
    // immediately and let the write settle behind it.
    await _tasks.reorder(ids);
  }

  Widget _row(OblixColors c, TaskRowValue row, {required bool first}) {
    final task = _byId[row.id];
    if (task == null) return const SizedBox.shrink();
    return Column(
      children: [
        if (!first) Divider(height: 1, indent: 33, color: c.hairline),
        TaskRowTile(
          task: task,
          row: row,
          onToggle: () => _toggle(task),
          onOpen: () => showTaskDetailSheet(context, task.id),
          onSwipe: (action) => _swipe(task, action),
        ),
      ],
    );
  }

  /// Empty is a state worth designing. "All clear" is a result, not an error,
  /// so it reads as one.
  Widget _empty(OblixColors c) {
    final isToday = _sameDay(_focus, _today);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          children: [
            Icon(
              isToday ? Icons.wb_sunny_outlined : Icons.event_available,
              size: 30,
              color: c.inkFaint,
            ),
            const SizedBox(height: 14),
            Text(
              isToday ? 'Nothing due today' : 'Nothing on ${_shortDay(_focus)}',
              style: TextStyle(
                fontFamily: OblixType.serif,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: c.inkSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Type below — try "pay rent friday 5pm p1".',
              textAlign: TextAlign.center,
              style: OblixType.ui(c, size: 13, color: c.inkMuted),
            ),
          ],
        ),
      ),
    );
  }

  static String _shortDay(DateTime day) {
    const months = [
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
    return '${months[day.month - 1]} ${day.day}';
  }
}

DateTime _startOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _firstOfMonth(DateTime value) => DateTime(value.year, value.month, 1);

bool _sameDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
