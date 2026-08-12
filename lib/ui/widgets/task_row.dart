import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/native/oblix_core.dart';
import '../../data/models/task.dart';
import '../theme/oblix_theme.dart';

/// What a swipe asked for.
enum TaskSwipe { schedule, delete }

/// One task.
///
/// Everything secondary — the due time, the repeat glyph, the subtask count,
/// the labels — only appears when it exists, so an ordinary task is a checkbox
/// and a line of text and a busy one is still legible. The old row could show a
/// time and a description; this can show why a task matters without ever
/// growing a second line for a task that has nothing to say.
class TaskRowTile extends StatelessWidget {
  const TaskRowTile({
    super.key,
    required this.task,
    required this.row,
    required this.onToggle,
    required this.onOpen,
    required this.onSwipe,
  });

  final Task task;
  final TaskRowValue row;
  final VoidCallback onToggle;
  final VoidCallback onOpen;
  final ValueChanged<TaskSwipe> onSwipe;

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Dismissible(
      key: ValueKey('task-${task.id}'),
      background: _swipeBackground(
        c,
        Alignment.centerLeft,
        Icons.event,
        'Schedule',
        c.accent,
      ),
      secondaryBackground: _swipeBackground(
        c,
        Alignment.centerRight,
        Icons.delete_outline,
        'Delete',
        c.danger,
      ),
      // Deleting is undoable from the snackbar, so neither direction needs a
      // confirmation dialog standing between the user and a one-second action.
      confirmDismiss: (direction) async {
        onSwipe(
          direction == DismissDirection.startToEnd
              ? TaskSwipe.schedule
              : TaskSwipe.delete,
        );
        // Rescheduling keeps the row (it may still belong to this day); the
        // list rebuilds from the database either way.
        return false;
      },
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: EdgeInsets.fromLTRB(row.depth * 22.0, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _checkbox(c),
              const SizedBox(width: 12),
              Expanded(child: _body(c)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _checkbox(OblixColors c) {
    final color = task.isCompleted
        ? c.accent
        : row.isOverdue
        ? c.danger
        : _priorityColor(c) ?? c.outline;
    return Semantics(
      checked: task.isCompleted,
      label: task.title,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onToggle();
        },
        // A 21px circle is a poor target; the padding makes it a real one
        // without changing how it looks.
        child: Padding(
          padding: const EdgeInsets.only(top: 1, right: 2, bottom: 2),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 21,
            height: 21,
            decoration: BoxDecoration(
              color: task.isCompleted ? c.accent : Colors.transparent,
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 2),
            ),
            child: task.isCompleted
                ? Icon(Icons.check, size: 13, color: c.onAccent)
                : null,
          ),
        ),
      ),
    );
  }

  Widget _body(OblixColors c) {
    final meta = _metaChips(c);
    return Column(
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
            decoration: task.isCompleted ? TextDecoration.lineThrough : null,
            decorationColor: c.inkFaint,
          ),
        ),
        if (meta.isNotEmpty && !task.isCompleted) ...[
          const SizedBox(height: 4),
          Wrap(spacing: 10, runSpacing: 4, children: meta),
        ],
      ],
    );
  }

  List<Widget> _metaChips(OblixColors c) {
    final due = task.dueDate?.toLocal();
    return [
      if (due != null && (task.dueHasTime || row.isOverdue))
        _meta(
          c,
          row.isOverdue ? Icons.error_outline : Icons.schedule,
          row.isOverdue ? _overdueLabel(due) : _clock(due),
          color: row.isOverdue ? c.danger : c.inkMuted,
          bold: row.isOverdue,
        ),
      if (task.repeats)
        _meta(c, Icons.repeat, _repeatLabel(), color: c.inkMuted),
      if (row.childTotal > 0)
        _meta(
          c,
          Icons.checklist,
          '${row.childDone}/${row.childTotal}',
          color: row.childDone == row.childTotal ? c.accentDeep : c.inkMuted,
        ),
      if (task.hasReminder)
        _meta(c, Icons.notifications_none, '', color: c.inkMuted),
      for (final label in task.labels.take(3))
        _meta(c, Icons.sell_outlined, label, color: c.inkMuted),
      if (task.description.isNotEmpty)
        _meta(c, Icons.notes, '', color: c.inkFaint),
    ];
  }

  Widget _meta(
    OblixColors c,
    IconData icon,
    String label, {
    required Color color,
    bool bold = false,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 11, color: color),
      if (label.isNotEmpty) ...[
        const SizedBox(width: 4),
        Text(
          label,
          style: OblixType.ui(
            c,
            size: 11.5,
            weight: bold ? FontWeight.w600 : FontWeight.w400,
            color: color,
          ),
        ),
      ],
    ],
  );

  /// The priority ring. Only urgent and high earn a colour — if every task can
  /// shout, none of them do.
  Color? _priorityColor(OblixColors c) => switch (task.priority) {
    TaskPriority.urgent => c.danger,
    TaskPriority.high => c.accent,
    _ => null,
  };

  String _repeatLabel() {
    final rule = parseRecurrence(task.recurrence ?? '');
    return rule == null ? 'Repeats' : describeRecurrence(rule);
  }

  static String _clock(DateTime local) {
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String _overdueLabel(DateTime due) {
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(due.year, due.month, due.day))
        .inDays;
    if (days <= 0) return _clock(due);
    if (days == 1) return 'Yesterday';
    if (days < 7) return '$days days late';
    if (days < 30) return '${days ~/ 7}w late';
    return '${days ~/ 30}mo late';
  }

  Widget _swipeBackground(
    OblixColors c,
    Alignment alignment,
    IconData icon,
    String label,
    Color color,
  ) => Container(
    color: color.withValues(alpha: 0.12),
    alignment: alignment,
    padding: const EdgeInsets.symmetric(horizontal: 22),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 7),
        Text(
          label,
          style: OblixType.ui(
            c,
            size: 13,
            weight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    ),
  );
}
