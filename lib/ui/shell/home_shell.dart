import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/auth/profile_cache.dart';
import '../screens/home_timeline_screen.dart';
import '../screens/notebooks_screen.dart';
import '../screens/scan_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/tasks_screen.dart';
import '../theme/oblix_theme.dart';
import '../theme/theme_controller.dart';
import '../widgets/paper.dart';
import 'dock_controller.dart';

/// The signed-in shell with a floating, Maps-style navigation dock. Its three
/// app shortcuts are user-arrangeable; Profile is intentionally fixed.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  static const _collapsedHeight = 92.0;
  static const _expandedHeight = 246.0;

  int _tab = 0;
  double _dockHeight = _collapsedHeight;
  bool _dragging = false;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    ProfileCache.instance.load();
  }

  void _onDragStart(DragStartDetails _) {
    setState(() => _dragging = true);
  }

  void _onDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dockHeight = (_dockHeight - details.delta.dy)
          .clamp(_collapsedHeight, _expandedHeight)
          .toDouble();
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dy;
    final expand =
        velocity < -280 ||
        (velocity < 280 &&
            _dockHeight > (_collapsedHeight + _expandedHeight) / 2);
    setState(() {
      _dragging = false;
      _dockHeight = expand ? _expandedHeight : _collapsedHeight;
      if (!expand) _editing = false;
    });
  }

  void _toggleDock() {
    final expand = _dockHeight == _collapsedHeight;
    setState(() {
      _dockHeight = expand ? _expandedHeight : _collapsedHeight;
      if (!expand) _editing = false;
    });
  }

  /// A destination either selects a tab or starts a capture flow. Scanning is
  /// the latter: it pushes its own route rather than becoming a tab, so the
  /// shell never shows it as "selected".
  void _openDestination(DockDestination destination) {
    final tab = destination.tabIndex;
    if (tab == null) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ScanScreen()),
      );
      return;
    }
    setState(() => _tab = tab);
  }

  void _openProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _pickShortcut(int slot) async {
    final c = OblixColors.of(context);
    final current = DockController.instance.order.value[slot];
    final choice = await showModalBottomSheet<DockDestination>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Choose shortcut', style: OblixType.cardTitle(c)),
              ),
            ),
            for (final destination in DockDestination.values)
              ListTile(
                leading: Icon(destination.icon, color: c.inkSecondary),
                title: Text(
                  destination.label,
                  style: OblixType.ui(c, size: 15),
                ),
                trailing: destination == current
                    ? Icon(Icons.check, size: 20, color: c.accent)
                    : null,
                onTap: () => Navigator.pop(context, destination),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (choice != null) {
      await DockController.instance.setDestination(slot, choice);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ThemeController.instance.liquidGlass,
      builder: (context, liquidGlass, _) => Scaffold(
        extendBody: true,
        body: IndexedStack(
          index: _tab,
          children: const [
            HomeTimelineScreen(),
            NotebooksScreen(),
            TasksScreen(),
          ],
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: AnimatedContainer(
                duration: _dragging
                    ? Duration.zero
                    : const Duration(milliseconds: 360),
                curve: Curves.easeOutCubic,
                width: double.infinity,
                height: _dockHeight,
                child: ValueListenableBuilder<List<DockDestination>>(
                  valueListenable: DockController.instance.order,
                  builder: (context, order, _) => NavigationDock(
                    order: order,
                    selectedTab: _tab,
                    editing: _editing,
                    liquidGlass: liquidGlass,
                    onDragStart: _onDragStart,
                    onDragUpdate: _onDragUpdate,
                    onDragEnd: _onDragEnd,
                    onToggle: _toggleDock,
                    onToggleEditing: () => setState(() => _editing = !_editing),
                    onDestination: _openDestination,
                    onPickShortcut: _pickShortcut,
                    onSwap: DockController.instance.assign,
                    onProfile: _openProfile,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rendered dock surface, public so it can be isolated in responsive widget
/// tests without booting repositories or authentication.
class NavigationDock extends StatelessWidget {
  final List<DockDestination> order;
  final int selectedTab;
  final bool editing;
  final bool liquidGlass;
  final GestureDragStartCallback onDragStart;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
  final VoidCallback onToggle;
  final VoidCallback onToggleEditing;
  final ValueChanged<DockDestination> onDestination;
  final ValueChanged<int> onPickShortcut;
  final Future<void> Function(DockDestination, DockDestination) onSwap;
  final VoidCallback onProfile;

  const NavigationDock({
    super.key,
    required this.order,
    required this.selectedTab,
    required this.editing,
    required this.liquidGlass,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onToggle,
    required this.onToggleEditing,
    required this.onDestination,
    required this.onPickShortcut,
    required this.onSwap,
    required this.onProfile,
  });

  /// Smallest box the expanded layout fits in: handle, header, the row of
  /// large slots, the tray and the footer hint.
  static const _expandedLayoutMinHeight = 218.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: onDragStart,
      onVerticalDragUpdate: onDragUpdate,
      onVerticalDragEnd: onDragEnd,
      child: _DockSurface(
        liquidGlass: liquidGlass,
        // Which layout to draw is a question about the box the dock is
        // actually in, not about the one it is heading for. [height] is the
        // target the caller is animating towards, and it arrives at its final
        // value on the first frame — so deciding from it renders the expanded
        // layout inside a box still 92px tall for the length of the animation,
        // which is an overflow every time the dock is opened. The constraints
        // are the honest answer at every frame.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final expanded = constraints.maxHeight >= _expandedLayoutMinHeight;
            return ClipRect(
              child: expanded
                  ? _ExpandedDock(
                      order: order,
                      selectedTab: selectedTab,
                      editing: editing,
                      onToggle: onToggle,
                      onToggleEditing: onToggleEditing,
                      onDestination: onDestination,
                      onPickShortcut: onPickShortcut,
                      onSwap: onSwap,
                      onProfile: onProfile,
                    )
                  : Column(
                      children: [
                        _DockHandle(onTap: onToggle),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                for (final destination in order)
                                  _CompactDockItem(
                                    icon: destination.icon,
                                    label: destination.label,
                                    selected:
                                        selectedTab == destination.tabIndex,
                                    onTap: () => onDestination(destination),
                                  ),
                                _ProfileDockItem(
                                  compact: true,
                                  editing: false,
                                  onTap: onProfile,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}

class _ExpandedDock extends StatelessWidget {
  final List<DockDestination> order;
  final int selectedTab;
  final bool editing;
  final VoidCallback onToggle;
  final VoidCallback onToggleEditing;
  final ValueChanged<DockDestination> onDestination;
  final ValueChanged<int> onPickShortcut;
  final Future<void> Function(DockDestination, DockDestination) onSwap;
  final VoidCallback onProfile;

  const _ExpandedDock({
    required this.order,
    required this.selectedTab,
    required this.editing,
    required this.onToggle,
    required this.onToggleEditing,
    required this.onDestination,
    required this.onPickShortcut,
    required this.onSwap,
    required this.onProfile,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Column(
      children: [
        _DockHandle(onTap: onToggle),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 14, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Your dock',
                  style: OblixType.ui(c, size: 17, weight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: onToggleEditing,
                child: Text(editing ? 'Done' : 'Customize'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (var i = 0; i < order.length; i++)
                  Expanded(
                    child: _EditableDockSlot(
                      destination: order[i],
                      selected: selectedTab == order[i].tabIndex,
                      editing: editing,
                      onTap: editing
                          ? () => onPickShortcut(i)
                          : () => onDestination(order[i]),
                      onSwap: onSwap,
                    ),
                  ),
                Expanded(
                  child: _ProfileDockItem(
                    compact: false,
                    editing: editing,
                    onTap: onProfile,
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 13),
          child: Text(
            editing
                ? 'Drag to reorder or tap a shortcut to replace it. Profile is fixed.'
                : 'Drag down to close',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: OblixType.ui(c, size: 11.5, color: c.inkMuted),
          ),
        ),
      ],
    );
  }
}

class _DockHandle extends StatelessWidget {
  final VoidCallback onTap;

  const _DockHandle({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Semantics(
      button: true,
      label: 'Expand or collapse navigation dock',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 24,
          child: Center(
            child: Container(
              width: 50,
              height: 5,
              decoration: BoxDecoration(
                color: c.inkFaint.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactDockItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CompactDockItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final color = selected ? c.accentDeep : c.inkMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 68,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 23, color: color),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OblixType.ui(
                    c,
                    size: 10.5,
                    weight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EditableDockSlot extends StatelessWidget {
  final DockDestination destination;
  final bool selected;
  final bool editing;
  final VoidCallback onTap;
  final Future<void> Function(DockDestination, DockDestination) onSwap;

  const _EditableDockSlot({
    required this.destination,
    required this.selected,
    required this.editing,
    required this.onTap,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final tile = _LargeDockItem(
      icon: destination.icon,
      label: destination.label,
      selected: selected,
      editing: editing,
      onTap: onTap,
    );
    final target = DragTarget<DockDestination>(
      onWillAcceptWithDetails: (details) => details.data != destination,
      onAcceptWithDetails: (details) => onSwap(details.data, destination),
      builder: (context, candidates, _) => AnimatedScale(
        duration: const Duration(milliseconds: 140),
        scale: candidates.isEmpty ? 1 : 1.08,
        child: tile,
      ),
    );
    if (!editing) return target;
    return LongPressDraggable<DockDestination>(
      data: destination,
      hapticFeedbackOnStart: true,
      feedback: Material(
        color: Colors.transparent,
        child: _LargeDockItem(
          icon: destination.icon,
          label: destination.label,
          selected: selected,
          editing: true,
          onTap: () {},
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: target),
      child: target,
    );
  }
}

class _LargeDockItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool editing;
  final VoidCallback onTap;

  const _LargeDockItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.editing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final iconColor = selected ? c.accentDeep : c.inkSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? c.accentSoft : c.surfaceAlt,
                        border: Border.all(
                          color: selected ? c.accent : c.hairline,
                        ),
                      ),
                      child: Icon(icon, size: 27, color: iconColor),
                    ),
                    if (editing)
                      Positioned(
                        right: -1,
                        top: -1,
                        child: Container(
                          width: 19,
                          height: 19,
                          decoration: BoxDecoration(
                            color: c.ink,
                            shape: BoxShape.circle,
                            border: Border.all(color: c.surface, width: 1.5),
                          ),
                          child: Icon(
                            Icons.drag_indicator,
                            size: 12,
                            color: c.surface,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OblixType.ui(
                    c,
                    size: 11.5,
                    weight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? c.ink : c.inkSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileDockItem extends StatelessWidget {
  final bool compact;
  final bool editing;
  final VoidCallback onTap;

  const _ProfileDockItem({
    required this.compact,
    required this.editing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    if (compact) {
      return Semantics(
        button: true,
        label: 'Profile',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 68,
            child: Padding(
              // Two rather than the four its neighbours use: an avatar is a
              // laid-out circle where their icons are glyphs, and at the same
              // nominal 23 it stands a pixel taller — enough to overflow the
              // collapsed row. The content is centred either way, so the
              // smaller inset costs nothing visually.
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ValueListenableBuilder<String?>(
                    valueListenable: ProfileCache.instance.name,
                    builder: (context, name, _) =>
                        OblixAvatar(name: name, size: 23),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Profile',
                    style: OblixType.ui(c, size: 10.5, color: c.inkMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      button: true,
      label: 'Profile, fixed shortcut',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ValueListenableBuilder<String?>(
                      valueListenable: ProfileCache.instance.name,
                      builder: (context, name, _) => Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          color: c.avatarBg,
                          shape: BoxShape.circle,
                          border: Border.all(color: c.hairline),
                        ),
                        child: Center(child: OblixAvatar(name: name, size: 42)),
                      ),
                    ),
                    if (editing)
                      Positioned(
                        right: -1,
                        top: -1,
                        child: Container(
                          width: 19,
                          height: 19,
                          decoration: BoxDecoration(
                            color: c.ink,
                            shape: BoxShape.circle,
                            border: Border.all(color: c.surface, width: 1.5),
                          ),
                          child: Icon(Icons.lock, size: 10, color: c.surface),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Profile',
                  style: OblixType.ui(c, size: 11.5, color: c.inkSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DockSurface extends StatelessWidget {
  final bool liquidGlass;
  final Widget child;

  const _DockSurface({required this.liquidGlass, required this.child});

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final brightness = Theme.of(context).brightness;
    final radius = BorderRadius.circular(34);
    final shadowColor = brightness == Brightness.dark
        ? Colors.black.withValues(alpha: 0.34)
        : Colors.black.withValues(alpha: 0.14);

    Widget surface;
    if (liquidGlass) {
      final tint = brightness == Brightness.dark
          ? c.surface.withValues(alpha: 0.58)
          : Colors.white.withValues(alpha: 0.56);
      surface = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: tint),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(
                        alpha: brightness == Brightness.dark ? 0.13 : 0.34,
                      ),
                      c.surface.withValues(alpha: 0.10),
                      c.accentSoft.withValues(alpha: 0.22),
                    ],
                    stops: const [0, 0.48, 1],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(
                      alpha: brightness == Brightness.dark ? 0.18 : 0.66,
                    ),
                  ),
                  borderRadius: radius,
                ),
              ),
              Positioned(
                left: 24,
                right: 24,
                top: 1,
                child: Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        Colors.white.withValues(alpha: 0.82),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
              Material(color: Colors.transparent, child: child),
            ],
          ),
        ),
      );
    } else {
      surface = Material(
        color: c.surface.withValues(alpha: 0.98),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: c.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: liquidGlass ? 30 : 18,
            offset: const Offset(0, 9),
            spreadRadius: -3,
          ),
        ],
      ),
      child: surface,
    );
  }
}
