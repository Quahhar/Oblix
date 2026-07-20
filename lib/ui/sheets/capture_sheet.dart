import 'package:flutter/material.dart';
import '../screens/note_editor_screen.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';
import 'new_task_sheet.dart';

/// The center "+" sheet: a 2-column grid of capture options. New note and
/// Task are live; Audio / Scan / Sketch / Web clip are designed features
/// whose logic isn't built yet, so they open a styled coming-soon sheet.
Future<void> showCaptureSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => const _CaptureSheet(),
  );
}

class _CaptureOption {
  final IconData icon;
  final String title;
  final String subtitle;
  const _CaptureOption(this.icon, this.title, this.subtitle);
}

class _CaptureSheet extends StatelessWidget {
  const _CaptureSheet();

  static const _options = <_CaptureOption>[
    _CaptureOption(Icons.description_outlined, 'New note', 'Blank page, cursor ready'),
    _CaptureOption(Icons.check_circle_outline, 'Task', 'With optional reminder'),
    _CaptureOption(Icons.mic_none, 'Audio', 'Records + transcribes'),
    _CaptureOption(Icons.crop_free, 'Scan', 'Paper to searchable PDF'),
    _CaptureOption(Icons.edit_outlined, 'Sketch', 'Pencil & paper canvas'),
    _CaptureOption(Icons.language, 'Web clip', 'Save a page or link'),
  ];

  void _select(BuildContext context, int index) {
    final option = _options[index];
    Navigator.pop(context);
    switch (index) {
      case 0:
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NoteEditorScreen()),
        );
      case 1:
        showNewTaskSheet(context);
      default:
        showComingSoon(
          context,
          icon: option.icon,
          title: option.title,
          subtitle: option.subtitle,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabHandle(),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.72,
              children: [
                for (var i = 0; i < _options.length; i++)
                  Material(
                    color: c.bg,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => _select(context, i),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(_options[i].icon, size: 22, color: c.accent),
                            const SizedBox(height: 10),
                            Text(
                              _options[i].title,
                              style: OblixType.ui(c,
                                  size: 14, weight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _options[i].subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OblixType.ui(c,
                                  size: 11, color: c.inkMuted),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Cancel',
                style: OblixType.ui(c,
                    size: 14, weight: FontWeight.w600, color: c.inkMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
