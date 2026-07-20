import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/models/task.dart';
import '../../data/repositories/task_repository.dart';
import '../sheets/new_task_sheet.dart';
import '../theme/oblix_theme.dart';
import '../util/formats.dart';
import '../widgets/paper.dart';

enum _TaskTab { open, scheduled, done }

/// The Tasks tab: Open / Scheduled / Done segments, groups by due date with
/// OVERDUE in red, tap the circle to complete, long-press to delete.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final _tasks = TaskRepository();

  _TaskTab _tab = _TaskTab.open;
  List<Task> _open = const [];
  List<Task> _done = const [];
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _tasks.onChanged.listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final open = await _tasks.listTasks();
    final done = await _tasks.listTasks(completed: true);
    if (!mounted) return;
    setState(() {
      _open = open;
      _done = done;
    });
  }

  Future<void> _delete(Task task) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete task?'),
        content: Text('"${task.title}" will be removed everywhere.'),
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
    if (confirmed ?? false) await _tasks.deleteTask(task.id);
  }

  List<Task> get _visible => switch (_tab) {
        _TaskTab.open => _open,
        _TaskTab.scheduled =>
          _open.where((t) => t.dueDate != null).toList(),
        _TaskTab.done => _done,
      };

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final groups = _tab == _TaskTab.done
        ? [_TaskGroup('COMPLETED', c.inkMuted, _done)]
        : _groupByDue(_visible, c);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: Text('Tasks', style: OblixType.pageTitle(c))),
                AccentPill(
                  label: 'New',
                  icon: Icons.add,
                  onTap: () => showNewTaskSheet(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: c.chip,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(
                children: [
                  _segment('Open · ${_open.length}', _TaskTab.open),
                  _segment('Scheduled', _TaskTab.scheduled),
                  _segment('Done', _TaskTab.done),
                ],
              ),
            ),
          ),
          if (_visible.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 60, 22, 0),
              child: Center(
                child: Text(
                  switch (_tab) {
                    _TaskTab.open => 'All clear — nothing to do.',
                    _TaskTab.scheduled => 'No scheduled tasks.',
                    _TaskTab.done => 'Nothing completed yet.',
                  },
                  style: OblixType.ui(c, size: 14, color: c.inkMuted),
                ),
              ),
            )
          else
            for (final group in groups) ...[
              SectionEyebrow(
                group.label,
                color: group.color,
                rule: true,
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 4),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Column(
                  children: [
                    for (var i = 0; i < group.tasks.length; i++) ...[
                      if (i > 0) Divider(height: 1, color: c.hairline),
                      _TaskRow(
                        task: group.tasks[i],
                        overdue: group.overdue,
                        onToggle: () => _tasks.setCompleted(
                            group.tasks[i].id, !group.tasks[i].isCompleted),
                        onLongPress: () => _delete(group.tasks[i]),
                      ),
                    ],
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }

  Widget _segment(String label, _TaskTab tab) {
    final c = OblixColors.of(context);
    final selected = _tab == tab;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = tab),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? c.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: c.ink.withValues(alpha: 0.08),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: OblixType.ui(
                c,
                size: 12.5,
                weight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? c.ink : c.inkMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<_TaskGroup> _groupByDue(List<Task> tasks, OblixColors c) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final overdue = <Task>[];
    final dated = <String, _TaskGroup>{};
    final anytime = <Task>[];

    for (final task in tasks) {
      final due = task.dueDate?.toLocal();
      if (due == null) {
        anytime.add(task);
        continue;
      }
      final day = DateTime(due.year, due.month, due.day);
      if (day.isBefore(today)) {
        overdue.add(task);
      } else {
        final label = Formats.dueGroup(due);
        final color = label == 'TODAY' ? c.accent : c.inkMuted;
        dated.putIfAbsent(label, () => _TaskGroup(label, color, [])).tasks
            .add(task);
      }
    }

    return [
      if (overdue.isNotEmpty)
        _TaskGroup('OVERDUE', c.danger, overdue, overdue: true),
      ...dated.values,
      if (anytime.isNotEmpty && _tab == _TaskTab.open)
        _TaskGroup('ANYTIME', c.inkMuted, anytime),
    ];
  }
}

class _TaskGroup {
  final String label;
  final Color color;
  final List<Task> tasks;
  final bool overdue;
  _TaskGroup(this.label, this.color, this.tasks, {this.overdue = false});
}

class _TaskRow extends StatelessWidget {
  final Task task;
  final bool overdue;
  final VoidCallback onToggle;
  final VoidCallback onLongPress;

  const _TaskRow({
    required this.task,
    required this.overdue,
    required this.onToggle,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final due = task.dueDate?.toLocal();
    return InkWell(
      onTap: onToggle,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: task.isCompleted
                  ? Container(
                      width: 21,
                      height: 21,
                      decoration:
                          BoxDecoration(color: c.accent, shape: BoxShape.circle),
                      child: Icon(Icons.check, size: 13, color: c.onAccent),
                    )
                  : Container(
                      width: 21,
                      height: 21,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: overdue ? c.danger : c.outline,
                          width: 2,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    style: OblixType.ui(
                      c,
                      size: 15,
                      weight: FontWeight.w500,
                      color: task.isCompleted ? c.inkFaint : c.ink,
                    ).copyWith(
                      decoration: task.isCompleted
                          ? TextDecoration.lineThrough
                          : null,
                      decorationColor: c.inkFaint,
                    ),
                  ),
                  if (!task.isCompleted &&
                      (due != null || task.description.isNotEmpty)) ...[
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        if (due != null) ...[
                          Icon(Icons.schedule,
                              size: 11,
                              color: overdue ? c.danger : c.inkMuted),
                          const SizedBox(width: 5),
                          Text(
                            overdue
                                ? Formats.relative(due)
                                : Formats.time(due),
                            style: OblixType.ui(
                              c,
                              size: 11.5,
                              weight: overdue
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: overdue ? c.danger : c.inkMuted,
                            ),
                          ),
                        ],
                        if (due != null && task.description.isNotEmpty)
                          const SizedBox(width: 8),
                        if (task.description.isNotEmpty)
                          Expanded(
                            child: Text(
                              task.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OblixType.ui(c,
                                  size: 11.5, color: c.inkMuted),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
