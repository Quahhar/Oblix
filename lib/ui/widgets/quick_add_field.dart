import 'package:flutter/material.dart';

import '../../core/native/oblix_core.dart';
import '../theme/oblix_theme.dart';

/// A text field that shows you what it understood, while you type.
///
/// The parser is only trustworthy if it is visible. Tinting `tomorrow 5pm p1`
/// as you type turns a hidden guess into a visible one you can correct — and
/// makes the whole grammar discoverable without a help screen, because the
/// moment a word lights up you know it counted.
///
/// Highlighting is a [TextEditingController] subclass rather than an overlay so
/// the spans move with the text through scrolling, selection and IME
/// composition automatically.
class QuickAddController extends TextEditingController {
  QuickAddController({super.text});

  List<QuickAddSpanValue> _spans = const [];

  /// Colours for the recognized runs. Set by the field on every rebuild so the
  /// controller stays theme-agnostic.
  Map<CoreQuickAddToken, Color> _palette = const {};

  set spans(List<QuickAddSpanValue> value) {
    if (_sameSpans(value, _spans)) return;
    _spans = value;
    notifyListeners();
  }

  set palette(Map<CoreQuickAddToken, Color> value) => _palette = value;

  static bool _sameSpans(
    List<QuickAddSpanValue> left,
    List<QuickAddSpanValue> right,
  ) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i].start != right[i].start ||
          left[i].end != right[i].end ||
          left[i].kind != right[i].kind) {
        return false;
      }
    }
    return true;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final value = text;
    if (_spans.isEmpty || value.isEmpty) {
      return TextSpan(text: value, style: style);
    }

    // Spans arrive in UTF-16 code units, which is exactly what String.substring
    // indexes by — so no conversion is needed, and an emoji in the title cannot
    // shift the highlight.
    final ordered = [..._spans]..sort((a, b) => a.start.compareTo(b.start));
    final children = <TextSpan>[];
    var cursor = 0;
    for (final span in ordered) {
      final start = span.start.clamp(0, value.length);
      final end = span.end.clamp(start, value.length);
      if (start < cursor) continue; // overlapping spans: first one wins
      if (start > cursor) {
        children.add(TextSpan(text: value.substring(cursor, start)));
      }
      children.add(
        TextSpan(
          text: value.substring(start, end),
          style: TextStyle(
            color: _palette[span.kind],
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      cursor = end;
    }
    if (cursor < value.length) {
      children.add(TextSpan(text: value.substring(cursor)));
    }
    return TextSpan(style: style, children: children);
  }
}

/// The one control that creates tasks.
///
/// There is no "new task" form any more. A single line, always reachable at the
/// bottom of the list, that understands dates, times, priorities, labels and
/// repetition. The old sheet's three hard-coded presets could express
/// "Tomorrow AM"; this can express "every other Tuesday at 4".
class QuickAddField extends StatefulWidget {
  const QuickAddField({
    super.key,
    required this.controller,
    required this.parse,
    required this.onSubmit,
    this.hint = 'Add a task…',
    this.autofocus = false,
  });

  final QuickAddController controller;

  /// Asked on every keystroke. Pure and fast — it is a parse over one line.
  final QuickAddParseValue Function(String text) parse;

  /// Called with the raw text; the caller re-parses and persists.
  final ValueChanged<String> onSubmit;

  final String hint;
  final bool autofocus;

  @override
  State<QuickAddField> createState() => _QuickAddFieldState();
}

class _QuickAddFieldState extends State<QuickAddField> {
  final _focus = FocusNode();
  QuickAddParseValue? _parsed;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_reparse);
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    widget.controller.removeListener(_reparse);
    _focus.dispose();
    super.dispose();
  }

  void _reparse() {
    final text = widget.controller.text;
    final parsed = text.trim().isEmpty ? null : widget.parse(text);
    widget.controller.spans = parsed?.spans ?? const [];
    if (mounted) setState(() => _parsed = parsed);
  }

  void _submit() {
    final text = widget.controller.text.trim();
    if (text.isEmpty) return;
    widget.onSubmit(text);
    widget.controller.clear();
    setState(() => _parsed = null);
    // Keep the field hot: adding one task usually means adding three.
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    widget.controller.palette = {
      CoreQuickAddToken.date: c.accentDeep,
      CoreQuickAddToken.time: c.accentDeep,
      CoreQuickAddToken.priority: c.danger,
      CoreQuickAddToken.project: c.inkSecondary,
      CoreQuickAddToken.label: c.inkSecondary,
      CoreQuickAddToken.recurrence: c.accentDeep,
      CoreQuickAddToken.reminder: c.accentDeep,
    };
    final summary = _summary();

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: _focus.hasFocus ? c.accent : c.hairline,
          width: _focus.hasFocus ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: c.ink.withValues(alpha: _focus.hasFocus ? 0.10 : 0.05),
            blurRadius: _focus.hasFocus ? 18 : 10,
            offset: const Offset(0, 4),
            spreadRadius: -4,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 14, right: 4),
                child: Icon(Icons.add, size: 20, color: c.inkMuted),
              ),
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focus,
                  autofocus: widget.autofocus,
                  textInputAction: TextInputAction.done,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) => _submit(),
                  style: OblixType.ui(c, size: 15.5),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 15),
                    hintText: widget.hint,
                    hintStyle: OblixType.ui(c, size: 15.5, color: c.inkFaint),
                  ),
                ),
              ),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 160),
                opacity: widget.controller.text.trim().isEmpty ? 0.35 : 1,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: IconButton(
                    onPressed: _submit,
                    icon: Icon(Icons.arrow_upward, size: 18, color: c.onAccent),
                    style: IconButton.styleFrom(
                      backgroundColor: c.accent,
                      minimumSize: const Size(34, 34),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ],
          ),
          // What the parser made of it, in plain English. The chips below the
          // field are the receipt for the highlighting above it.
          if (summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 11),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final chip in summary) _chip(c, chip.$1, chip.$2),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(OblixColors c, IconData icon, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: c.accentSoft,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: c.accentDeep),
        const SizedBox(width: 4),
        Text(
          label,
          style: OblixType.ui(
            c,
            size: 11.5,
            weight: FontWeight.w600,
            color: c.accentDeep,
          ),
        ),
      ],
    ),
  );

  List<(IconData, String)> _summary() {
    final parsed = _parsed;
    if (parsed == null) return const [];
    return [
      if (parsed.due != null)
        (Icons.event, _dueLabel(parsed.due!, parsed.dueTime)),
      if (parsed.recurrence != null)
        (
          Icons.repeat,
          describeRecurrence(
            parseRecurrence(parsed.recurrence!) ??
                (
                  freq: CoreRecurrenceFreq.daily,
                  interval: 1,
                  byWeekday: const [],
                  mode: CoreRecurrenceMode.schedule,
                ),
          ),
        ),
      if (parsed.priority > 0)
        (Icons.flag, TaskPriorityLabels.of(parsed.priority)),
      if (parsed.project != null) (Icons.folder_outlined, parsed.project!),
      for (final label in parsed.labels) (Icons.sell_outlined, label),
      if (parsed.reminderLeadMinutes != null)
        (Icons.notifications_none, _leadLabel(parsed.reminderLeadMinutes!)),
    ];
  }

  static String _dueLabel(CivilDateValue date, CivilTimeValue? time) {
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
    final today = DateTime.now();
    final resolved = DateTime(date.year, date.month, date.day);
    final days = resolved
        .difference(DateTime(today.year, today.month, today.day))
        .inDays;
    final day = switch (days) {
      0 => 'Today',
      1 => 'Tomorrow',
      -1 => 'Yesterday',
      _ => '${months[date.month - 1]} ${date.day}',
    };
    if (time == null) return day;
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final minute = time.minute.toString().padLeft(2, '0');
    return '$day, $hour:$minute ${time.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String _leadLabel(int minutes) {
    if (minutes == 0) return 'At due time';
    if (minutes % 1440 == 0) return '${minutes ~/ 1440}d before';
    if (minutes % 60 == 0) return '${minutes ~/ 60}h before';
    return '${minutes}m before';
  }
}

/// Priority names, shared by the chip row and the detail sheet.
abstract final class TaskPriorityLabels {
  static String of(int priority) => switch (priority) {
    3 => 'Urgent',
    2 => 'High',
    1 => 'Medium',
    _ => 'None',
  };
}
