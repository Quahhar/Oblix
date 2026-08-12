import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/models/note.dart';
import '../../data/models/notebook.dart';
import '../../data/models/tag.dart';
import '../../data/datasources/remote/collaboration_remote_datasource.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../../data/repositories/tag_repository.dart';
import '../sheets/manage_access_sheet.dart';
import '../theme/oblix_theme.dart';
import '../widgets/note_timeline.dart';
import '../widgets/paper.dart';
import 'note_editor_screen.dart';

/// One notebook: eyebrow, big serif name, note count, and its notes in the same
/// day-grouped list the Notes page uses. "+" creates a note inside this
/// notebook; "⋯" offers rename/delete.
class NotebookDetailScreen extends StatefulWidget {
  final Notebook notebook;
  const NotebookDetailScreen({super.key, required this.notebook});

  @override
  State<NotebookDetailScreen> createState() => _NotebookDetailScreenState();
}

class _NotebookDetailScreenState extends State<NotebookDetailScreen> {
  final _notes = NoteRepository();
  final _notebooks = NotebookRepository();
  final _collaborationRemote = CollaborationRemoteDataSource();

  late Notebook _book = widget.notebook;
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
    final notes = await _notes.listNotes(notebookId: _book.id);
    if (!mounted) return;
    setState(() => _items = notes);
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _book.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename notebook'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && name != _book.name) {
      final updated = await _notebooks.updateNotebook(_book.id, name: name);
      if (mounted) setState(() => _book = updated);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete notebook?'),
        content: Text(
          '"${_book.name}" will be deleted. Its notes are kept and remain '
          'under Notes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await _notebooks.deleteNotebook(_book.id);
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _manageAccess() => showManageAccessSheet(
    context,
    remote: _collaborationRemote,
    entityType: 'notebook',
    entityId: _book.id,
    name: _book.name,
  );

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
              child: Row(
                children: [
                  CircleIconButton(
                    Icons.arrow_back_ios_new,
                    size: 32,
                    onTap: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  CircleIconButton(
                    Icons.add,
                    size: 32,
                    tooltip: 'New note here',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            NoteEditorScreen(initialNotebookId: _book.id),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  CircleIconButton(
                    Icons.group_outlined,
                    size: 32,
                    tooltip: 'Manage access',
                    onTap: _manageAccess,
                  ),
                  const SizedBox(width: 10),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_horiz, color: c.ink),
                    onSelected: (v) => v == 'rename' ? _rename() : _delete(),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('NOTEBOOK', style: OblixType.eyebrow(c)),
                  const SizedBox(height: 8),
                  Text(_book.name, style: OblixType.pageTitle(c)),
                  const SizedBox(height: 6),
                  Text(
                    '${_items.length} ${_items.length == 1 ? 'note' : 'notes'}',
                    style: OblixType.ui(c, size: 12.5, color: c.inkMuted),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Text(
                        'Nothing here yet, tap + to add a note.',
                        style: OblixType.ui(c, size: 14, color: c.inkMuted),
                      ),
                    )
                  : NoteTimelineList(
                      notes: _items,
                      padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
                      horizontalMargin: 22,
                      onOpen: (note) => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NoteEditorScreen(noteId: note.id),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Notes filtered by one tag, in the same day-grouped list.
class TagNotesScreen extends StatefulWidget {
  final Tag tag;
  const TagNotesScreen({super.key, required this.tag});

  @override
  State<TagNotesScreen> createState() => _TagNotesScreenState();
}

class _TagNotesScreenState extends State<TagNotesScreen> {
  final _notes = NoteRepository();
  final _tags = TagRepository();
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
    final notes = await _notes.listNotes(tagName: widget.tag.name);
    if (!mounted) return;
    setState(() => _items = notes);
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete tag?'),
        content: Text(
          '"#${widget.tag.name}" will be removed from your tag list.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await _tags.deleteTag(widget.tag.id);
      if (mounted) Navigator.pop(context);
    }
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
              child: Row(
                children: [
                  CircleIconButton(
                    Icons.arrow_back_ios_new,
                    size: 32,
                    onTap: () => Navigator.pop(context),
                  ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_horiz, color: c.ink),
                    onSelected: (_) => _delete(),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'delete', child: Text('Delete tag')),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TAG', style: OblixType.eyebrow(c)),
                  const SizedBox(height: 8),
                  Text('#${widget.tag.name}', style: OblixType.pageTitle(c)),
                  const SizedBox(height: 6),
                  Text(
                    '${_items.length} ${_items.length == 1 ? 'note' : 'notes'}',
                    style: OblixType.ui(c, size: 12.5, color: c.inkMuted),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Text(
                        'No notes carry this tag.',
                        style: OblixType.ui(c, size: 14, color: c.inkMuted),
                      ),
                    )
                  : NoteTimelineList(
                      notes: _items,
                      padding: const EdgeInsets.fromLTRB(0, 4, 0, 24),
                      horizontalMargin: 22,
                      onOpen: (note) => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => NoteEditorScreen(noteId: note.id),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
