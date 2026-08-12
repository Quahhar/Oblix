import 'package:flutter/material.dart';

import '../../core/native/oblix_core.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../../domain/services/task_reminder_service.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';

/// Everything about one task, on one sheet.
///
/// The list stays quiet by keeping detail out of it; this is where the detail
/// goes. It is a sheet rather than a page so the task never leaves its context
/// — you can see the day you came from behind it.
Future<void> showTaskDetailSheet(BuildContext context, String taskId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _TaskDetailSheet(taskId: taskId),
  );
}

class _TaskDetailSheet extends StatefulWidget {
  const _TaskDetailSheet({required this.taskId});
  final String taskId;

  @override
  State<_TaskDetailSheet> createState() => _TaskDetailSheetState();
}

class _TaskDetailSheetState extends State<_TaskDetailSheet> {
  final _tasks = TaskRepository();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _subtask = TextEditingController();

  Task? _task;
  List<Task> _children = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _subtask.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final task = await _tasks.getTask(widget.taskId);
    final children = await _tasks.listTasks(
      completed: null,
      parentId: widget.taskId,
    );
    if (!mounted || task == null) return;
    setState(() {
      _task = task;
      _children = children;
      if (_title.text != task.title) _title.text = task.title;
      if (_description.text != task.description) {
        _description.text = task.description;
      }
    });
  }

  Future<void> _apply(Future<void> Function() mutation) async {
    await mutation();
    await _load();
  }

  Future<void> _pickDate() async {
    final task = _task;
    if (task == null) return;
    final now = DateTime.now();
    final current = task.dueDate?.toLocal();
    final date = await showDatePicker(
      context: context,
      initialDate: current ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 10),
    );
    if (date == null || !mounted) return;

    // Offering the clock only after a day is chosen keeps the common case —
    // "sometime on Thursday" — to a single tap.
    final wantsTime = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabHandle(),
            ListTile(
              leading: const Icon(Icons.today),
              title: const Text('All day'),
              onTap: () => Navigator.pop(context, false),
            ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: const Text('Pick a time'),
              onTap: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted) return;

    var due = DateTime(date.year, date.month, date.day);
    var hasTime = false;
    if (wantsTime ?? false) {
      final time = await showTimePicker(
        context: context,
        initialTime: current != null && task.dueHasTime
            ? TimeOfDay.fromDateTime(current)
            : const TimeOfDay(hour: 9, minute: 0),
      );
      if (time != null) {
        due = DateTime(date.year, date.month, date.day, time.hour, time.minute);
        hasTime = true;
      }
    }
    await _apply(
      () => _tasks.updateTask(
        task.id,
        dueDate: due.toUtc(),
        dueHasTime: hasTime,
      ),
    );
  }

  Future<void> _pickPriority() async {
    final task = _task;
    if (task == null) return;
    final choice = await showModalBottomSheet<TaskPriority>(
      context: context,
      builder: (context) {
        final c = OblixColors.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetGrabHandle(),
              for (final priority in TaskPriority.values.reversed)
                ListTile(
                  leading: Icon(
                    priority == TaskPriority.none
                        ? Icons.outlined_flag
                        : Icons.flag,
                    color: switch (priority) {
                      TaskPriority.urgent => c.danger,
                      TaskPriority.high => c.accent,
                      TaskPriority.low => c.inkSecondary,
                      TaskPriority.none => c.inkFaint,
                    },
                  ),
                  title: Text(priority.label, style: OblixType.ui(c, size: 15)),
                  trailing: priority == task.priority
                      ? Icon(Icons.check, size: 20, color: c.accent)
                      : null,
                  onTap: () => Navigator.pop(context, priority),
                ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
    if (choice == null) return;
    await _apply(() => _tasks.updateTask(task.id, priority: choice));
  }

  Future<void> _pickRepeat() async {
    final task = _task;
    if (task == null) return;
    final options = <(String, String?)>[
      ('Does not repeat', null),
      ('Every day', 'FREQ=DAILY;INTERVAL=1'),
      ('Every weekday', 'FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR'),
      ('Every week', 'FREQ=WEEKLY;INTERVAL=1'),
      ('Every 2 weeks', 'FREQ=WEEKLY;INTERVAL=2'),
      ('Every month', 'FREQ=MONTHLY;INTERVAL=1'),
      ('Every year', 'FREQ=YEARLY;INTERVAL=1'),
    ];
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (context) {
        final c = OblixColors.of(context);
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SheetGrabHandle(),
                SectionEyebrow(
                  'Repeat',
                  padding: const EdgeInsets.fromLTRB(22, 2, 22, 4),
                ),
                for (var i = 0; i < options.length; i++)
                  ListTile(
                    title: Text(
                      options[i].$1,
                      style: OblixType.ui(c, size: 15),
                    ),
                    trailing: options[i].$2 == task.recurrence
                        ? Icon(Icons.check, size: 20, color: c.accent)
                        : null,
                    onTap: () => Navigator.pop(context, i),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 6, 22, 16),
                  child: Text(
                    'Tip: typing "every other tuesday" when you add a task '
                    'sets this for you.',
                    style: OblixType.ui(c, size: 12, color: c.inkMuted),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null) return;
    final rule = options[choice].$2;
    await _apply(
      () => _tasks.updateTask(
        task.id,
        recurrence: rule,
        clearRecurrence: rule == null,
      ),
    );
  }

  Future<void> _pickReminder() async {
    final task = _task;
    if (task == null) return;
    if (task.dueDate == null) {
      _toast('Give the task a date first');
      return;
    }
    final options = <(String, int?)>[
      ('No reminder', null),
      ('At the due time', 0),
      ('10 minutes before', 10),
      ('30 minutes before', 30),
      ('1 hour before', 60),
      ('1 day before', 1440),
    ];
    final choice = await showModalBottomSheet<int>(
      context: context,
      builder: (context) {
        final c = OblixColors.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetGrabHandle(),
              for (var i = 0; i < options.length; i++)
                ListTile(
                  title: Text(options[i].$1, style: OblixType.ui(c, size: 15)),
                  trailing: options[i].$2 == task.reminderLeadMinutes
                      ? Icon(Icons.check, size: 20, color: c.accent)
                      : null,
                  onTap: () => Navigator.pop(context, i),
                ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
    if (choice == null) return;
    final lead = options[choice].$2;
    if (lead != null) {
      // Ask at the moment the user first wants to be interrupted, not on
      // first launch when the request has no context.
      final granted = await TaskReminderService.instance.requestPermission();
      if (!granted && mounted) {
        _toast('Notifications are turned off for Oblix');
      }
    }
    await _apply(
      () => _tasks.updateTask(
        task.id,
        reminderLeadMinutes: lead,
        clearReminder: lead == null,
      ),
    );
  }

  Future<void> _editLabels() async {
    final task = _task;
    if (task == null) return;
    final controller = TextEditingController(text: task.labels.join(', '));
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Labels'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'email, calls'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    await _apply(
      () => _tasks.updateTask(
        task.id,
        labels: result
            .split(',')
            .map((label) => label.trim())
            .where((label) => label.isNotEmpty)
            .toList(),
      ),
    );
  }

  Future<void> _addSubtask() async {
    final text = _subtask.text.trim();
    if (text.isEmpty) return;
    _subtask.clear();
    await _apply(
      () => _tasks.createFromQuickAdd(text, parentId: widget.taskId),
    );
  }

  Future<void> _delete() async {
    final task = _task;
    if (task == null) return;
    final childCount = _children.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete task?'),
        content: Text(
          childCount == 0
              ? '"${task.title}" will be removed everywhere.'
              : '"${task.title}" and its $childCount '
                    '${childCount == 1 ? 'subtask' : 'subtasks'} '
                    'will be removed everywhere.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await _tasks.deleteTask(task.id);
    if (mounted) Navigator.pop(context);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final task = _task;
    if (task == null) {
      return const SizedBox(height: 220, child: Center(child: CircularProgressIndicator()));
    }
    final due = task.dueDate?.toLocal();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetGrabHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 14, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: GestureDetector(
                        onTap: () async {
                          final navigator = Navigator.of(context);
                          await _tasks.setCompleted(task.id, !task.isCompleted);
                          if (mounted) navigator.pop();
                        },
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: task.isCompleted
                                ? c.accent
                                : Colors.transparent,
                            shape: BoxShape.circle,
                            border: Border.all(color: c.outline, width: 2),
                          ),
                          child: task.isCompleted
                              ? Icon(Icons.check, size: 14, color: c.onAccent)
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _title,
                        maxLines: null,
                        style: TextStyle(
                          fontFamily: OblixType.serif,
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onEditingComplete: () => _apply(
                          () => _tasks.updateTask(
                            task.id,
                            title: _title.text.trim(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(56, 2, 22, 0),
                child: TextField(
                  controller: _description,
                  maxLines: null,
                  style: OblixType.ui(c, size: 14.5, color: c.body),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: 'Add notes…',
                    hintStyle: OblixType.ui(c, size: 14.5, color: c.inkFaint),
                  ),
                  onEditingComplete: () => _apply(
                    () => _tasks.updateTask(
                      task.id,
                      description: _description.text,
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 10),
              _attribute(
                c,
                Icons.event,
                due == null
                    ? 'No date'
                    : _dateLabel(due, task.dueHasTime),
                onTap: _pickDate,
                onClear: due == null
                    ? null
                    : () => _apply(
                        () => _tasks.updateTask(task.id, clearDueDate: true),
                      ),
                highlighted: due != null,
              ),
              _attribute(
                c,
                task.priority == TaskPriority.none
                    ? Icons.outlined_flag
                    : Icons.flag,
                task.priority.label,
                onTap: _pickPriority,
                highlighted: task.priority != TaskPriority.none,
              ),
              _attribute(
                c,
                Icons.repeat,
                task.repeats
                    ? describeRecurrence(
                        parseRecurrence(task.recurrence!) ??
                            (
                              freq: CoreRecurrenceFreq.daily,
                              interval: 1,
                              byWeekday: const [],
                              mode: CoreRecurrenceMode.schedule,
                            ),
                      )
                    : 'Does not repeat',
                onTap: _pickRepeat,
                highlighted: task.repeats,
              ),
              _attribute(
                c,
                Icons.notifications_none,
                task.reminderLeadMinutes == null
                    ? 'No reminder'
                    : _reminderLabel(task.reminderLeadMinutes!),
                onTap: _pickReminder,
                highlighted: task.hasReminder,
              ),
              _attribute(
                c,
                Icons.sell_outlined,
                task.labels.isEmpty ? 'No labels' : task.labels.join(', '),
                onTap: _editLabels,
                highlighted: task.labels.isNotEmpty,
              ),

              SectionEyebrow(
                _children.isEmpty
                    ? 'Subtasks'
                    : 'Subtasks · '
                          '${_children.where((child) => child.isCompleted).length}'
                          '/${_children.length}',
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 2),
              ),
              for (final child in _children)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => _apply(
                          () => _tasks.setCompleted(
                            child.id,
                            !child.isCompleted,
                          ),
                        ),
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          child.isCompleted
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          size: 19,
                          color: child.isCompleted ? c.accent : c.outline,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          child.title,
                          style: OblixType.ui(
                            c,
                            size: 14.5,
                            color: child.isCompleted ? c.inkFaint : c.ink,
                          ).copyWith(
                            decoration: child.isCompleted
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 4, 22, 0),
                child: Row(
                  children: [
                    Icon(Icons.add, size: 18, color: c.inkMuted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _subtask,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _addSubtask(),
                        style: OblixType.ui(c, size: 14.5),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: 'Add a step…',
                          hintStyle: OblixType.ui(
                            c,
                            size: 14.5,
                            color: c.inkFaint,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
                child: TextButton.icon(
                  onPressed: _delete,
                  icon: Icon(Icons.delete_outline, size: 18, color: c.danger),
                  label: Text(
                    'Delete task',
                    style: OblixType.ui(c, size: 14, color: c.danger),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attribute(
    OblixColors c,
    IconData icon,
    String label, {
    required VoidCallback onTap,
    VoidCallback? onClear,
    bool highlighted = false,
  }) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(22, 11, 14, 11),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: highlighted ? c.accentDeep : c.inkMuted,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OblixType.ui(
                c,
                size: 14.5,
                weight: highlighted ? FontWeight.w500 : FontWeight.w400,
                color: highlighted ? c.ink : c.inkSecondary,
              ),
            ),
          ),
          if (onClear != null)
            IconButton(
              onPressed: onClear,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 16, color: c.inkFaint),
            ),
        ],
      ),
    ),
  );

  static String _dateLabel(DateTime due, bool hasTime) {
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
    final now = DateTime.now();
    final days = DateTime(due.year, due.month, due.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final day = switch (days) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => '${months[due.month - 1]} ${due.day}',
    };
    if (!hasTime) return day;
    final hour = due.hour % 12 == 0 ? 12 : due.hour % 12;
    final minute = due.minute.toString().padLeft(2, '0');
    return '$day at $hour:$minute ${due.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String _reminderLabel(int minutes) {
    if (minutes == 0) return 'At the due time';
    if (minutes % 1440 == 0) {
      final days = minutes ~/ 1440;
      return '$days ${days == 1 ? 'day' : 'days'} before';
    }
    if (minutes % 60 == 0) {
      final hours = minutes ~/ 60;
      return '$hours ${hours == 1 ? 'hour' : 'hours'} before';
    }
    return '$minutes minutes before';
  }
}
