import 'package:flutter/material.dart';

import '../../core/native/oblix_core.dart';
import '../../data/models/note.dart';
import '../sheets/note_actions_sheet.dart';
import '../theme/oblix_theme.dart';
import '../util/formats.dart';
import 'paper.dart';

/// The canonical note list: a heading with a card of rows beneath each.
///
/// Headings are time windows that widen as they recede — TODAY, YESTERDAY,
/// PREVIOUS 7 DAYS, PREVIOUS 30 DAYS, then a month and finally a year — so a
/// long history reads as a handful of sections instead of one per calendar day.
///
/// Notes, notebook detail, and tag views all render this, so a note looks the
/// same wherever it is listed. Grouping and the row snippet come from the Rust
/// core ([groupNotesByDay], [noteSnippet]) — Dart only converts each timestamp
/// to the device's local civil date first, since the core is built without a
/// timezone database on purpose.
class NoteTimelineList extends StatelessWidget {
  const NoteTimelineList({
    super.key,
    required this.notes,
    required this.onOpen,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 24),
    this.horizontalMargin = 20,
    this.shrinkWrap = false,
    this.physics,
    this.leading = const [],
  });

  final List<Note> notes;
  final void Function(Note) onOpen;
  final EdgeInsetsGeometry padding;
  final double horizontalMargin;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  /// Widgets rendered above the first heading, inside the same scroll view.
  final List<Widget> leading;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      shrinkWrap: shrinkWrap,
      physics: physics,
      children: [
        ...leading,
        ...buildGroupedSections(
          context,
          notes: notes,
          onOpen: onOpen,
          horizontalMargin: horizontalMargin,
        ),
      ],
    );
  }
}

/// The heading + card sections on their own, for screens that already own a
/// scroll view (the Notes timeline composes them alongside pinned cards).
List<Widget> buildGroupedSections(
  BuildContext context, {
  required List<Note> notes,
  required void Function(Note) onOpen,
  double horizontalMargin = 20,
}) {
  final c = OblixColors.of(context);
  final byId = {for (final note in notes) note.id: note};
  final sections = <Widget>[];
  for (final group in groupNotesForDisplay(notes)) {
    final rows = [for (final id in group.noteIds) ?byId[id]];
    if (rows.isEmpty) continue;
    sections.add(
      SectionEyebrow(
        group.label,
        padding: EdgeInsets.fromLTRB(horizontalMargin, 18, horizontalMargin, 8),
      ),
    );
    sections.add(
      PaperCard(
        margin: EdgeInsets.symmetric(horizontal: horizontalMargin),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(height: 1, color: c.hairline),
              NoteTimelineRow(
                note: rows[i],
                onTap: () => onOpen(rows[i]),
                onLongPress: () => showNoteActionsSheet(context, rows[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }
  return sections;
}

/// Localize each note's `updatedAt` and let the core do the grouping.
List<NoteDayGroupValue> groupNotesForDisplay(
  List<Note> notes, {
  DateTime? now,
}) {
  final today = (now ?? DateTime.now()).toLocal();
  return groupNotesByDay(
    notes: [
      for (final note in notes)
        () {
          final local = note.updatedAt.toLocal();
          return (
            id: note.id,
            localYear: local.year,
            localMonth: local.month,
            localDay: local.day,
          );
        }(),
    ],
    todayYear: today.year,
    todayMonth: today.month,
    todayDay: today.day,
  );
}

/// One note in a list: title, its date or time, snippet, and up to three tags.
class NoteTimelineRow extends StatelessWidget {
  const NoteTimelineRow({
    super.key,
    required this.note,
    required this.onTap,
    required this.onLongPress,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final snippet = noteSnippet(note.content);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    note.title.isEmpty ? 'Untitled' : note.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OblixType.cardTitle(c),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  Formats.listStamp(note.updatedAt),
                  style: OblixType.meta(c),
                ),
              ],
            ),
            if (snippet.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                snippet,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OblixType.snippet(c),
              ),
            ],
            if (note.tagNames.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final tag in note.tagNames.take(3))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: c.accentSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '#$tag',
                        style: OblixType.ui(c, size: 11.5, color: c.accentDeep),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
