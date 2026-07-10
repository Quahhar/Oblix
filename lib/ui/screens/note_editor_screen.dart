import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/models/note.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../../data/repositories/tag_repository.dart';

/// Full-screen note editor with debounced autosave. A brand-new note is only
/// created once something is typed (no empty notes from an accidental FAB
/// tap); after that every pause persists locally and syncs in the background.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, this.noteId, this.initialNotebookId});

  /// Existing note to edit; null starts a new draft.
  final String? noteId;

  /// Notebook a new note is filed into (the list's active filter).
  final String? initialNotebookId;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  final _repo = NoteRepository();
  final _notebooks = NotebookRepository();
  final _tags = TagRepository();

  final _title = TextEditingController();
  final _content = TextEditingController();

  Note? _note;
  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.noteId != null) {
      final note = await _repo.getNote(widget.noteId!);
      if (note != null) {
        _note = note;
        _title.text = note.title == 'Untitled' ? '' : note.title;
        _content.text = note.content;
      }
    }
    // Attach listeners only after the initial text is in, so loading a note
    // doesn't count as an edit.
    _title.addListener(_onEdited);
    _content.addListener(_onEdited);
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    // Flush a pending edit. _save reads the controllers synchronously before
    // its first await, so disposing them right after is safe.
    if (_dirty) _save();
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  void _onEdited() {
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), _save);
  }

  Future<void> _save() async {
    if (!_dirty || _saving) return;
    _saving = true;
    _dirty = false;
    final title = _title.text.trim();
    final content = _content.text;
    try {
      final current = _note;
      if (current == null) {
        if (title.isEmpty && content.trim().isEmpty) return;
        _note = await _repo.createNote(
          title: title.isEmpty ? 'Untitled' : title,
          content: content,
          notebookId: widget.initialNotebookId,
        );
      } else {
        _note = await _repo.updateNote(
          current.id,
          title: title.isEmpty ? 'Untitled' : title,
          content: content,
        );
      }
    } finally {
      _saving = false;
      // An edit arrived while saving — persist it too.
      if (_dirty) unawaited(_save());
    }
  }

  /// Run [action] with autosave settled first, so it operates on the saved row.
  Future<void> _withSavedNote(
    Future<void> Function(Note note) action,
  ) async {
    _debounce?.cancel();
    await _save();
    final note = _note;
    if (note != null) await action(note);
  }

  Future<void> _togglePin() => _withSavedNote((note) async {
        _note = await _repo.updateNote(note.id, isPinned: !note.isPinned);
        if (mounted) setState(() {});
      });

  Future<void> _toggleArchive() => _withSavedNote((note) async {
        _note = await _repo.updateNote(note.id, isArchived: !note.isArchived);
        if (mounted) setState(() {});
      });

  Future<void> _delete() => _withSavedNote((note) async {
        await _repo.deleteNote(note.id);
        if (mounted) Navigator.pop(context);
      });

  Future<void> _moveToNotebook() => _withSavedNote((note) async {
        final notebooks = await _notebooks.listNotebooks();
        if (!mounted) return;
        final choice = await showModalBottomSheet<List<String?>>(
          context: context,
          builder: (context) => SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: const Icon(Icons.folder_off_outlined),
                  title: const Text('No notebook'),
                  selected: note.notebookId == null,
                  onTap: () => Navigator.pop(context, [null]),
                ),
                for (final nb in notebooks)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(nb.name),
                    selected: nb.id == note.notebookId,
                    onTap: () => Navigator.pop(context, [nb.id]),
                  ),
              ],
            ),
          ),
        );
        if (choice != null) {
          _note = await _repo.moveToNotebook(note.id, choice.single);
          if (mounted) setState(() {});
        }
      });

  Future<void> _editTags() => _withSavedNote((note) async {
        final controller =
            TextEditingController(text: note.tagNames.join(', '));
        final result = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Tags'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'work, ideas, todo',
                helperText: 'Separate tags with commas',
              ),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('Save'),
              ),
            ],
          ),
        );
        if (result == null) return;
        final names = <String>[];
        for (final raw in result.split(',')) {
          final name = raw.trim();
          if (name.isNotEmpty && !names.contains(name)) names.add(name);
        }
        _note = await _repo.updateNote(note.id, tagNames: names);
        // Make sure every name exists as a Tag entity so it shows up in the
        // drawer immediately (the server would create it on sync anyway).
        final known = (await _tags.listTags()).map((t) => t.name).toSet();
        for (final name in names) {
          if (!known.contains(name)) await _tags.createTag(name);
        }
        if (mounted) setState(() {});
      });

  @override
  Widget build(BuildContext context) {
    final note = _note;
    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            icon: Icon(
              (note?.isPinned ?? false)
                  ? Icons.push_pin
                  : Icons.push_pin_outlined,
            ),
            tooltip: (note?.isPinned ?? false) ? 'Unpin' : 'Pin',
            onPressed: _togglePin,
          ),
          PopupMenuButton<String>(
            onSelected: (action) => switch (action) {
              'move' => _moveToNotebook(),
              'tags' => _editTags(),
              'archive' => _toggleArchive(),
              'delete' => _delete(),
              _ => Future<void>.value(),
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'move', child: Text('Move to notebook')),
              const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
              PopupMenuItem(
                value: 'archive',
                child: Text(
                  (note?.isArchived ?? false) ? 'Unarchive' : 'Archive',
                ),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _title,
                    textInputAction: TextInputAction.next,
                    style: Theme.of(context).textTheme.headlineSmall,
                    decoration: const InputDecoration(
                      hintText: 'Title',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                if (note != null && note.tagNames.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 4,
                        children: [
                          for (final tag in note.tagNames)
                            Chip(
                              label: Text(tag),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: TextField(
                      controller: _content,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        hintText: 'Start writing…',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
