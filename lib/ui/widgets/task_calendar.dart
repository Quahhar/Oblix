import 'package:flutter/material.dart';

import '../../core/native/oblix_core.dart';
import '../theme/oblix_theme.dart';

/// How much calendar is on screen.
enum CalendarMode {
  /// Just the date line. The default, and the reason the screen stays quiet.
  collapsed,

  /// A single week strip.
  week,

  /// The full month grid.
  month,
}

/// The date header *is* the calendar.
///
/// Evernote puts its calendar in a separate widget, which means a second
/// surface to find, learn and maintain. Here the line that already had to say
/// what day it is expands in place: tap for the week, pull for the month, tap a
/// day to retarget the list beneath. Collapsed — which is how it spends most of
/// its life — it costs one line of text and no chrome at all.
class TaskCalendar extends StatelessWidget {
  const TaskCalendar({
    super.key,
    required this.mode,
    required this.today,
    required this.focus,
    required this.visibleMonth,
    required this.density,
    required this.openCount,
    required this.overdueCount,
    required this.onModeChanged,
    required this.onFocusChanged,
    required this.onMonthChanged,
  });

  final CalendarMode mode;
  final DateTime today;
  final DateTime focus;

  /// First day of the month the grid is showing. Follows [focus] unless the
  /// user is paging ahead.
  final DateTime visibleMonth;

  /// One entry per day of [visibleMonth], from the core.
  final List<CalendarDayValue> density;

  final int openCount;
  final int overdueCount;

  final ValueChanged<CalendarMode> onModeChanged;
  final ValueChanged<DateTime> onFocusChanged;
  final ValueChanged<DateTime> onMonthChanged;

  static const _weekdayInitials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const _weekdayNames = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  bool get _focusIsToday => _sameDay(focus, today);

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragEnd: (details) {
        final velocity = details.velocity.pixelsPerSecond.dy;
        if (velocity > 120) {
          onModeChanged(switch (mode) {
            CalendarMode.collapsed => CalendarMode.week,
            CalendarMode.week || CalendarMode.month => CalendarMode.month,
          });
        } else if (velocity < -120) {
          onModeChanged(switch (mode) {
            CalendarMode.month => CalendarMode.week,
            CalendarMode.week || CalendarMode.collapsed =>
              CalendarMode.collapsed,
          });
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(context, c),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: switch (mode) {
              CalendarMode.collapsed => const SizedBox(width: double.infinity),
              CalendarMode.week => _weekStrip(context, c),
              CalendarMode.month => _monthGrid(context, c),
            },
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, OblixColors c) {
    final subtitle = _focusIsToday
        ? _weekdayNames[today.weekday - 1]
        : '${_monthNames[focus.month - 1]} ${focus.day}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 14, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: mode == CalendarMode.collapsed
                  ? 'Show calendar'
                  : 'Hide calendar',
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onModeChanged(
                  mode == CalendarMode.collapsed
                      ? CalendarMode.week
                      : CalendarMode.collapsed,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        subtitle.toUpperCase(),
                        style: OblixType.eyebrow(c),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            _focusIsToday ? 'Today' : _focusLabel(),
                            style: OblixType.pageTitle(c),
                          ),
                          const SizedBox(width: 6),
                          AnimatedRotation(
                            duration: const Duration(milliseconds: 220),
                            turns: mode == CalendarMode.collapsed ? 0 : 0.5,
                            child: Icon(
                              Icons.keyboard_arrow_down,
                              size: 22,
                              color: c.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _remaining(c),
        ],
      ),
    );
  }

  String _focusLabel() {
    final difference = _startOfDay(focus).difference(_startOfDay(today)).inDays;
    if (difference == 1) return 'Tomorrow';
    if (difference == -1) return 'Yesterday';
    if (difference > 1 && difference < 7) return _weekdayNames[focus.weekday - 1];
    return '${_monthNames[focus.month - 1].substring(0, 3)} ${focus.day}';
  }

  /// The one number worth showing: what is still open. Overdue takes over the
  /// slot when there is any, because that is the more urgent fact.
  Widget _remaining(OblixColors c) {
    if (overdueCount > 0) {
      return _countPill('$overdueCount late', c.danger, c);
    }
    if (openCount == 0) {
      return _countPill('Clear', c.inkMuted, c);
    }
    return _countPill('$openCount left', c.inkSecondary, c);
  }

  Widget _countPill(String label, Color color, OblixColors c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: OblixType.ui(c, size: 12, weight: FontWeight.w600, color: color),
    ),
  );

  Widget _weekStrip(BuildContext context, OblixColors c) {
    final monday = _startOfDay(focus).subtract(Duration(days: focus.weekday - 1));
    return Column(
      key: const ValueKey(CalendarMode.week),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
          child: Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(child: _dayCell(context, c, monday.add(Duration(days: i)))),
            ],
          ),
        ),
        _grabber(c, CalendarMode.month),
      ],
    );
  }

  Widget _monthGrid(BuildContext context, OblixColors c) {
    final first = DateTime(visibleMonth.year, visibleMonth.month, 1);
    final leading = first.weekday - 1; // Monday-first
    final length = density.length;
    final cells = <Widget>[];
    for (var i = 0; i < leading; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var day = 1; day <= length; day++) {
      cells.add(
        _dayCell(context, c, DateTime(first.year, first.month, day)),
      );
    }
    while (cells.length % 7 != 0) {
      cells.add(const SizedBox.shrink());
    }

    return Column(
      key: const ValueKey(CalendarMode.month),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 14, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_monthNames[visibleMonth.month - 1]} ${visibleMonth.year}',
                  style: OblixType.ui(c, size: 14.5, weight: FontWeight.w600),
                ),
              ),
              _monthArrow(c, Icons.chevron_left, -1),
              _monthArrow(c, Icons.chevron_right, 1),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              for (final initial in _weekdayInitials)
                Expanded(
                  child: Center(
                    child: Text(initial, style: OblixType.eyebrow(c)),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
          child: Column(
            children: [
              for (var row = 0; row < cells.length / 7; row++)
                Row(
                  children: [
                    for (var column = 0; column < 7; column++)
                      Expanded(child: cells[row * 7 + column]),
                  ],
                ),
            ],
          ),
        ),
        _grabber(c, CalendarMode.week),
      ],
    );
  }

  Widget _monthArrow(OblixColors c, IconData icon, int delta) => IconButton(
    onPressed: () => onMonthChanged(
      DateTime(visibleMonth.year, visibleMonth.month + delta, 1),
    ),
    icon: Icon(icon, size: 20, color: c.inkSecondary),
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
  );

  /// The pull-target between week and month. Doubles as a tap affordance,
  /// because a 4px line is a poor drag handle on a phone.
  Widget _grabber(OblixColors c, CalendarMode target) => Semantics(
    button: true,
    label: target == CalendarMode.month ? 'Show month' : 'Show week',
    child: InkWell(
      onTap: () => onModeChanged(target),
      child: SizedBox(
        height: 22,
        width: double.infinity,
        child: Center(
          child: Container(
            width: 36,
            height: 3,
            decoration: BoxDecoration(
              color: c.inkFaint.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _dayCell(BuildContext context, OblixColors c, DateTime day) {
    final selected = _sameDay(day, focus);
    final isToday = _sameDay(day, today);
    final inVisibleMonth =
        day.year == visibleMonth.year && day.month == visibleMonth.month;
    final info = inVisibleMonth && day.day <= density.length
        ? density[day.day - 1]
        : null;

    final numberColor = selected
        ? c.onAccent
        : isToday
        ? c.accentDeep
        : inVisibleMonth || mode == CalendarMode.week
        ? c.ink
        : c.inkFaint;

    return Semantics(
      button: true,
      selected: selected,
      label: '${_weekdayNames[day.weekday - 1]} ${day.day}'
          '${info != null && info.openCount > 0 ? ', ${info.openCount} tasks' : ''}',
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onFocusChanged(_startOfDay(day)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mode == CalendarMode.week)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    _weekdayInitials[day.weekday - 1],
                    style: OblixType.eyebrow(
                      c,
                      color: selected ? c.accentDeep : c.inkMuted,
                    ),
                  ),
                ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: selected ? c.accent : Colors.transparent,
                  shape: BoxShape.circle,
                  border: isToday && !selected
                      ? Border.all(color: c.accent, width: 1.5)
                      : null,
                ),
                child: Center(
                  child: Text(
                    '${day.day}',
                    style: OblixType.ui(
                      c,
                      size: 13.5,
                      weight: selected || isToday
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: numberColor,
                    ),
                  ),
                ),
              ),
              SizedBox(height: 6, child: _densityMark(c, info, selected)),
            ],
          ),
        ),
      ),
    );
  }

  /// Up to three dots, so a heavy day reads as heavy without needing a number.
  /// A day that had work and finished it gets a single faint tick instead —
  /// quieter than a dot, and worth seeing.
  Widget _densityMark(OblixColors c, CalendarDayValue? info, bool selected) {
    if (info == null) return const SizedBox.shrink();
    if (info.openCount == 0) {
      if (!info.allDone) return const SizedBox.shrink();
      return Icon(
        Icons.check,
        size: 9,
        color: selected ? c.onAccent : c.inkFaint,
      );
    }
    final color = selected
        ? c.onAccent
        : info.hasOverdue
        ? c.danger
        : info.hasUrgent
        ? c.accent
        : c.inkMuted;
    final dots = info.openCount.clamp(1, 3);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < dots; i++)
          Container(
            width: 4,
            height: 4,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
      ],
    );
  }
}

DateTime _startOfDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

bool _sameDay(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;
