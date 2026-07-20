import 'package:flutter/material.dart';
import '../../data/models/note.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';

/// Long-press actions on a note: pin, move to notebook, archive, trash.
/// Mutations go straight through the repository; screens refresh via the
/// shared onChanged stream.
Future<void> showNoteActionsSheet(BuildContext context, Note note) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => _NoteActionsSheet(note: note),
  );
}

class _NoteActionsSheet extends StatelessWidget {
  final Note note;
  const _NoteActionsSheet({required this.note});

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final notes = NoteRepository();

    Widget row(IconData icon, String label,
        {Color? color, required VoidCallback onTap}) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color ?? c.inkSecondary),
              const SizedBox(width: 14),
              Text(label,
                  style: OblixType.ui(c,
                      size: 15, weight: FontWeight.w500, color: color)),
            ],
          ),
        ),
      );
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SheetGrabHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                note.title.isEmpty ? 'Untitled' : note.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: OblixType.serif,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: c.ink,
                ),
              ),
            ),
          ),
          row(
            note.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            note.isPinned ? 'Unpin' : 'Pin to top',
            onTap: () async {
              Navigator.pop(context);
              await notes.updateNote(note.id, isPinned: !note.isPinned);
            },
          ),
          row(
            Icons.folder_open_outlined,
            'Move to notebook',
            onTap: () async {
              Navigator.pop(context);
              await _moveToNotebook(context, note);
            },
          ),
          row(
            note.isArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
            note.isArchived ? 'Unarchive' : 'Archive',
            onTap: () async {
              Navigator.pop(context);
              await notes.updateNote(note.id, isArchived: !note.isArchived);
            },
          ),
          row(
            Icons.delete_outline,
            'Move to trash',
            color: c.danger,
            onTap: () async {
              Navigator.pop(context);
              await notes.deleteNote(note.id);
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: const Text('Note moved to trash'),
                      action: SnackBarAction(
                        label: 'Undo',
                        onPressed: () => notes.restoreNote(note.id),
                      ),
                    ),
                  );
              }
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  static Future<void> _moveToNotebook(BuildContext context, Note note) async {
    final notebooks = await NotebookRepository().listNotebooks();
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        final c = OblixColors.of(context);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const SheetGrabHandle(),
              ListTile(
                leading: Icon(Icons.folder_off_outlined, color: c.inkSecondary),
                title: Text('No notebook', style: OblixType.ui(c, size: 15)),
                onTap: () async {
                  Navigator.pop(context);
                  await NoteRepository().moveToNotebook(note.id, null);
                },
              ),
              for (final nb in notebooks)
                ListTile(
                  leading:
                      Icon(Icons.menu_book_outlined, color: c.inkSecondary),
                  title: Text(nb.name, style: OblixType.ui(c, size: 15)),
                  selected: nb.id == note.notebookId,
                  onTap: () async {
                    Navigator.pop(context);
                    await NoteRepository().moveToNotebook(note.id, nb.id);
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}
