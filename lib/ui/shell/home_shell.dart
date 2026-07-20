import 'package:flutter/material.dart';
import '../../core/auth/profile_cache.dart';
import '../screens/home_timeline_screen.dart';
import '../screens/notebooks_screen.dart';
import '../screens/tasks_screen.dart';
import '../sheets/capture_sheet.dart';
import '../theme/oblix_theme.dart';

/// The signed-in shell: Notes / Books / + / Tasks. The center "+" is not a
/// tab — it opens the capture sheet over whatever is showing.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    ProfileCache.instance.load();
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: const [
          HomeTimelineScreen(),
          NotebooksScreen(),
          TasksScreen(),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: c.bg.withValues(alpha: 0.94),
          border: Border(top: BorderSide(color: c.hairline)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _NavItem(
                  icon: Icons.description_outlined,
                  label: 'Notes',
                  selected: _tab == 0,
                  onTap: () => setState(() => _tab = 0),
                ),
                _NavItem(
                  icon: Icons.menu_book_outlined,
                  label: 'Books',
                  selected: _tab == 1,
                  onTap: () => setState(() => _tab = 1),
                ),
                _NavItem(
                  icon: Icons.add,
                  label: 'New',
                  accent: true,
                  onTap: () => showCaptureSheet(context),
                ),
                _NavItem(
                  icon: Icons.check_circle_outline,
                  label: 'Tasks',
                  selected: _tab == 2,
                  onTap: () => setState(() => _tab = 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool accent;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    this.selected = false,
    this.accent = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final color = accent
        ? c.accent
        : selected
            ? c.ink
            : c.inkFaint;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                style: OblixType.ui(
                  c,
                  size: 10,
                  weight: selected || accent ? FontWeight.w600 : FontWeight.w400,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
