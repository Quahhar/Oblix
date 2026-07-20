import 'package:flutter/material.dart';
import '../../data/repositories/task_repository.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';

/// Bottom sheet for creating a task: title with a check circle, REMIND ME
/// presets that set the due date, optional details, terracotta "Add task" CTA.
/// Returns true if a task was created.
Future<bool> showNewTaskSheet(BuildContext context) async {
  final created = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _NewTaskSheet(),
  );
  return created ?? false;
}

class _DuePreset {
  final String label;
  final DateTime? Function() resolve;
  const _DuePreset(this.label, this.resolve);
}

class _NewTaskSheet extends StatefulWidget {
  const _NewTaskSheet();

  @override
  State<_NewTaskSheet> createState() => _NewTaskSheetState();
}

class _NewTaskSheetState extends State<_NewTaskSheet> {
  final _tasks = TaskRepository();
  final _titleCtrl = TextEditingController();
  final _detailsCtrl = TextEditingController();

  static final _presets = <_DuePreset>[
    _DuePreset('Today 5:00 PM', () {
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day, 17);
    }),
    _DuePreset('Tonight', () {
      final now = DateTime.now();
      return DateTime(now.year, now.month, now.day, 20);
    }),
    _DuePreset('Tomorrow AM', () {
      final now = DateTime.now().add(const Duration(days: 1));
      return DateTime(now.year, now.month, now.day, 9);
    }),
  ];

  int? _selectedPreset;
  DateTime? _pickedDate;
  bool _saving = false;

  DateTime? get _dueDate {
    if (_pickedDate != null) return _pickedDate;
    if (_selectedPreset != null) return _presets[_selectedPreset!].resolve();
    return null;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _detailsCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _pickedDate ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365 * 5)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 9, minute: 0),
    );
    setState(() {
      _pickedDate = DateTime(date.year, date.month, date.day,
          time?.hour ?? 9, time?.minute ?? 0);
      _selectedPreset = null;
    });
  }

  Future<void> _submit() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    await _tasks.createTask(
      title: title,
      description: _detailsCtrl.text.trim(),
      dueDate: _dueDate?.toUtc(),
    );
    if (mounted) Navigator.pop(context, true);
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    final c = OblixColors.of(context);
    return Material(
      color: selected ? c.accent : c.surfaceAlt,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Text(
            label,
            style: OblixType.ui(
              c,
              size: 13,
              weight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? c.onAccent : c.avatarInk,
            ),
          ),
        ),
      ),
    );
  }

  String _formatPicked(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final ap = d.hour >= 12 ? 'PM' : 'AM';
    return '${months[d.month - 1]} ${d.day} · $h:$m $ap';
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Padding(
      // Keep the CTA above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetGrabHandle(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.only(top: 8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: c.outline, width: 2),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _titleCtrl,
                        autofocus: true,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        style: TextStyle(
                          fontFamily: OblixType.serif,
                          fontSize: 21,
                          fontWeight: FontWeight.w500,
                          color: c.ink,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'New task…',
                          hintStyle: TextStyle(
                            fontFamily: OblixType.serif,
                            fontSize: 21,
                            fontWeight: FontWeight.w500,
                            color: c.inkFaint,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SectionEyebrow('Remind me',
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0)),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 11, 24, 0),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < _presets.length; i++)
                      _chip(_presets[i].label, _selectedPreset == i, () {
                        setState(() {
                          _selectedPreset = _selectedPreset == i ? null : i;
                          _pickedDate = null;
                        });
                      }),
                    _chip(
                      _pickedDate != null
                          ? _formatPicked(_pickedDate!)
                          : 'Pick date…',
                      _pickedDate != null,
                      _pickDate,
                    ),
                  ],
                ),
              ),
              SectionEyebrow('Details',
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 0)),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: TextField(
                  controller: _detailsCtrl,
                  maxLines: 2,
                  minLines: 1,
                  style: OblixType.ui(c, size: 14.5),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Add details…',
                    hintStyle:
                        OblixType.ui(c, size: 14.5, color: c.inkMuted),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
                child: SizedBox(
                  width: double.infinity,
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _titleCtrl,
                    builder: (context, value, _) {
                      final enabled =
                          value.text.trim().isNotEmpty && !_saving;
                      return Material(
                        color: enabled
                            ? c.accent
                            : c.accent.withValues(alpha: 0.4),
                        shape: const StadiumBorder(),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: enabled ? _submit : null,
                          child: Padding(
                            padding: const EdgeInsets.all(15),
                            child: Center(
                              child: Text(
                                'Add task',
                                style: OblixType.ui(c,
                                    size: 15.5,
                                    weight: FontWeight.w600,
                                    color: c.onAccent),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
