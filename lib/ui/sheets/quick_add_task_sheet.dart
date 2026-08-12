import 'package:flutter/material.dart';

import '../../data/repositories/task_repository.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';
import '../widgets/quick_add_field.dart';

/// Capture a task from anywhere in the app.
///
/// The same one-line control the Tasks screen uses, so the grammar a user
/// learns in one place works in the other. It replaces a form with three
/// hard-coded time presets — "Today 5:00 PM", "Tonight", "Tomorrow AM" — that
/// could not express a fourth option, let alone a repeating one.
///
/// Returns true if a task was created.
Future<bool> showQuickAddTaskSheet(BuildContext context, {String? notebookId}) async {
  final created = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _QuickAddTaskSheet(notebookId: notebookId),
  );
  return created ?? false;
}

class _QuickAddTaskSheet extends StatefulWidget {
  const _QuickAddTaskSheet({this.notebookId});
  final String? notebookId;

  @override
  State<_QuickAddTaskSheet> createState() => _QuickAddTaskSheetState();
}

class _QuickAddTaskSheetState extends State<_QuickAddTaskSheet> {
  final _tasks = TaskRepository();
  final _controller = QuickAddController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit(String text) async {
    if (_saving) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    await _tasks.createFromQuickAdd(text, notebookId: widget.notebookId);
    if (mounted) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SheetGrabHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
              child: Text('New task', style: OblixType.cardTitle(c)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: QuickAddField(
                controller: _controller,
                parse: _tasks.previewQuickAdd,
                onSubmit: _submit,
                autofocus: true,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
              child: Text(
                'Dates, times, priorities and repeats are understood as you '
                'type — "call mum tomorrow 6pm" is one line.',
                style: OblixType.ui(c, size: 12, color: c.inkMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
