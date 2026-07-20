import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/models/note.dart';
import '../../data/repositories/note_repository.dart';
import '../theme/oblix_theme.dart';
import '../util/formats.dart';
import '../widgets/paper.dart';
import 'note_editor_screen.dart';

/// Archived notes — kept out of the timeline but not deleted. The design has
/// no archive screen of its own, so this follows the Trash layout.
class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  final _notes = NoteRepository();
  List<Note> _items = const [];
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _notes.onChanged.listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final notes = await _notes.listNotes(archived: true);
    if (!mounted) return;
    setState(() => _items = notes);
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: CircleIconButton(
                Icons.arrow_back_ios_new,
                size: 32,
                onTap: () => Navigator.pop(context),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
              child: Text('Archive', style: OblixType.pageTitle(c)),
            ),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Text(
                        'Nothing archived.',
                        style: OblixType.ui(c, size: 14, color: c.inkMuted),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
                      itemCount: _items.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: c.hairline),
                      itemBuilder: (context, index) {
                        final note = _items[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: c.chip,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(Icons.archive_outlined,
                                    size: 17, color: c.inkMuted),
                              ),
                              const SizedBox(width: 13),
                              Expanded(
                                child: InkWell(
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          NoteEditorScreen(noteId: note.id),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        note.title.isEmpty
                                            ? 'Untitled'
                                            : note.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: OblixType.cardTitle(c),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(Formats.relative(note.updatedAt),
                                          style: OblixType.meta(c)),
                                    ],
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: Icon(Icons.unarchive_outlined,
                                    size: 18, color: c.accent),
                                tooltip: 'Unarchive',
                                onPressed: () => _notes.updateNote(note.id,
                                    isArchived: false),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
