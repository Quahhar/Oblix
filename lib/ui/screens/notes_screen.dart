import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/app_bootstrap.dart';
import '../../data/models/note.dart';
import '../../data/models/notebook.dart';
import '../../data/models/tag.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../../data/repositories/tag_repository.dart';
import 'note_editor_screen.dart';

enum NotesView { all, archive, trash }

/// The main screen: note list with search, a drawer for notebooks/tags/
/// archive/trash, manual sync, and a FAB to create notes. All reads come from
/// local SQLite and refresh whenever the repositories broadcast a change
/// (local edit or background sync merge).
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  final _notes = NoteRepository();
  final _notebooks = NotebookRepository();
  final _tags = TagRepository();

  NotesView _view = NotesView.all;
  Notebook? _notebookFilter;
  Tag? _tagFilter;

  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  bool _searchOpen = false;
  String _search = '';

  List<Note> _items = const [];
  List<Notebook> _notebookList = const [];
  List<Tag> _tagList = const [];
  StreamSubscription<void>? _changesSub;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _changesSub = _notes.onChanged.listen((_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final notes = await _notes.listNotes(
      notebookId: _notebookFilter?.id,
      archived: switch (_view) {
        NotesView.all => false,
        NotesView.archive => true,
        NotesView.trash => null,
      },
      deleted: _view == NotesView.trash,
      search: _search.isEmpty ? null : _search,
      tagName: _tagFilter?.name,
    );
    final notebooks = await _notebooks.listNotebooks();
    final tags = await _tags.listTags();
    if (!mounted) return;
    setState(() {
      _items = notes;
      _notebookList = notebooks;
      _tagList = tags;
    });
  }

  // --- Sync ---

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    final result = await AppBootstrap.scheduler.syncNow();
    if (!mounted) return;
    setState(() => _syncing = false);
    if (result.skipped) return;
    final message = result.success
        ? 'Synced — ${result.pushed} pushed, ${result.pulled} pulled'
            '${result.rejected > 0 ? ', ${result.rejected} rejected' : ''}'
        : 'Sync failed — changes are kept locally and will retry';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Filters ---

  void _select(NotesView view, {Notebook? notebook, Tag? tag}) {
    setState(() {
      _view = view;
      _notebookFilter = notebook;
      _tagFilter = tag;
    });
    Navigator.pop(context); // close drawer
    _reload();
  }

  String get _title {
    if (_notebookFilter != null) return _notebookFilter!.name;
    if (_tagFilter != null) return '#${_tagFilter!.name}';
    return switch (_view) {
      NotesView.all => 'All notes',
      NotesView.archive => 'Archive',
      NotesView.trash => 'Trash',
    };
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _search = value.trim());
      _reload();
    });
  }

  // --- Note actions ---

  void _openEditor({String? noteId}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NoteEditorScreen(
          noteId: noteId,
          initialNotebookId: _notebookFilter?.id,
        ),
      ),
    );
  }

  Future<void> _onNoteAction(Note note, String action) async {
    switch (action) {
      case 'pin':
        await _notes.updateNote(note.id, isPinned: !note.isPinned);
      case 'archive':
        await _notes.updateNote(note.id, isArchived: true);
      case 'unarchive':
        await _notes.updateNote(note.id, isArchived: false);
      case 'move':
        await _moveToNotebook(note);
      case 'delete':
        await _notes.deleteNote(note.id);
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: const Text('Note moved to trash'),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () => _notes.restoreNote(note.id),
                ),
              ),
            );
        }
      case 'restore':
        await _notes.restoreNote(note.id);
    }
  }

  Future<void> _moveToNotebook(Note note) async {
    final choice = await showModalBottomSheet<_NotebookChoice>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: const Text('No notebook'),
              onTap: () =>
                  Navigator.pop(context, const _NotebookChoice(null)),
            ),
            for (final nb in _notebookList)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(nb.name),
                selected: nb.id == note.notebookId,
                onTap: () => Navigator.pop(context, _NotebookChoice(nb.id)),
              ),
          ],
        ),
      ),
    );
    if (choice != null) {
      await _notes.moveToNotebook(note.id, choice.notebookId);
    }
  }

  // --- Notebook / tag management ---

  Future<String?> _promptText(String title, {String? initial}) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
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
  }

  Future<void> _createNotebook() async {
    final name = await _promptText('New notebook');
    if (name != null && name.isNotEmpty) {
      await _notebooks.createNotebook(name: name);
    }
  }

  Future<void> _renameNotebook(Notebook nb) async {
    final name = await _promptText('Rename notebook', initial: nb.name);
    if (name != null && name.isNotEmpty && name != nb.name) {
      await _notebooks.updateNotebook(nb.id, name: name);
    }
  }

  Future<void> _deleteNotebook(Notebook nb) async {
    final confirmed = await _confirm(
      'Delete notebook?',
      '"${nb.name}" will be deleted. Its notes are kept and remain under '
          'All notes.',
    );
    if (confirmed) {
      await _notebooks.deleteNotebook(nb.id);
      if (_notebookFilter?.id == nb.id) {
        setState(() => _notebookFilter = null);
        await _reload();
      }
    }
  }

  Future<void> _renameTag(Tag tag) async {
    final name = await _promptText('Rename tag', initial: tag.name);
    if (name != null && name.isNotEmpty && name != tag.name) {
      await _tags.renameTag(tag.id, name);
    }
  }

  Future<void> _deleteTag(Tag tag) async {
    final confirmed = await _confirm(
      'Delete tag?',
      '"${tag.name}" will be removed from your tag list.',
    );
    if (confirmed) {
      await _tags.deleteTag(tag.id);
      if (_tagFilter?.id == tag.id) {
        setState(() => _tagFilter = null);
        await _reload();
      }
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
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
    return result ?? false;
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Unsynced changes are pushed first if possible. Local data on this '
          'device is then removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await AppBootstrap.signOut();
    }
  }

  // --- Build ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searchOpen
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search notes…',
                  border: InputBorder.none,
                ),
                onChanged: _onSearchChanged,
              )
            : Text(_title),
        actions: [
          IconButton(
            icon: Icon(_searchOpen ? Icons.close : Icons.search),
            tooltip: 'Search',
            onPressed: () {
              setState(() {
                _searchOpen = !_searchOpen;
                if (!_searchOpen) {
                  _searchCtrl.clear();
                  _search = '';
                }
              });
              if (!_searchOpen) _reload();
            },
          ),
          IconButton(
            icon: _syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            tooltip: 'Sync now',
            onPressed: _syncing ? null : _syncNow,
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: RefreshIndicator(
        onRefresh: _syncNow,
        child: _items.isEmpty
            ? LayoutBuilder(
                builder: (context, constraints) => ListView(
                  children: [
                    SizedBox(
                      height: constraints.maxHeight,
                      child: Center(
                        child: Text(
                          _search.isNotEmpty
                              ? 'No notes match your search'
                              : switch (_view) {
                                  NotesView.all =>
                                    'No notes yet — tap + to write one',
                                  NotesView.archive => 'Nothing archived',
                                  NotesView.trash => 'Trash is empty',
                                },
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) =>
                    _buildNoteTile(_items[index]),
              ),
      ),
      floatingActionButton: _view == NotesView.all
          ? FloatingActionButton(
              onPressed: () => _openEditor(),
              tooltip: 'New note',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildNoteTile(Note note) {
    final snippet = note.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return ListTile(
      leading: note.isPinned
          ? const Icon(Icons.push_pin, size: 20)
          : const SizedBox(width: 20),
      title: Text(
        note.title.isEmpty ? 'Untitled' : note.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (snippet.isNotEmpty)
            Text(snippet, maxLines: 2, overflow: TextOverflow.ellipsis),
          if (note.tagNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                children: [
                  for (final tag in note.tagNames)
                    Chip(
                      label: Text(tag),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      labelStyle: Theme.of(context).textTheme.labelSmall,
                    ),
                ],
              ),
            ),
        ],
      ),
      onTap: _view == NotesView.trash
          ? () => _onNoteAction(note, 'restore')
          : () => _openEditor(noteId: note.id),
      trailing: PopupMenuButton<String>(
        onSelected: (action) => _onNoteAction(note, action),
        itemBuilder: (context) => switch (_view) {
          NotesView.all => [
              PopupMenuItem(
                value: 'pin',
                child: Text(note.isPinned ? 'Unpin' : 'Pin'),
              ),
              const PopupMenuItem(value: 'move', child: Text('Move to notebook')),
              const PopupMenuItem(value: 'archive', child: Text('Archive')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          NotesView.archive => const [
              PopupMenuItem(value: 'unarchive', child: Text('Unarchive')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          NotesView.trash => const [
              PopupMenuItem(value: 'restore', child: Text('Restore')),
            ],
        },
      ),
    );
  }

  Widget _buildDrawer() {
    final theme = Theme.of(context);
    final isAll =
        _view == NotesView.all && _notebookFilter == null && _tagFilter == null;
    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            ListTile(
              leading: Icon(Icons.edit_note, color: theme.colorScheme.primary),
              title: Text('Cyclux', style: theme.textTheme.titleLarge),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.notes),
              title: const Text('All notes'),
              selected: isAll,
              onTap: () => _select(NotesView.all),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('Archive'),
              selected: _view == NotesView.archive,
              onTap: () => _select(NotesView.archive),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Trash'),
              selected: _view == NotesView.trash,
              onTap: () => _select(NotesView.trash),
            ),
            const Divider(),
            ListTile(
              dense: true,
              title: Text('NOTEBOOKS', style: theme.textTheme.labelSmall),
              trailing: IconButton(
                icon: const Icon(Icons.add, size: 20),
                tooltip: 'New notebook',
                onPressed: _createNotebook,
              ),
            ),
            for (final nb in _notebookList)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(nb.name),
                selected: _notebookFilter?.id == nb.id,
                onTap: () => _select(NotesView.all, notebook: nb),
                trailing: PopupMenuButton<String>(
                  onSelected: (action) => action == 'rename'
                      ? _renameNotebook(nb)
                      : _deleteNotebook(nb),
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ),
            if (_tagList.isNotEmpty) ...[
              const Divider(),
              ListTile(
                dense: true,
                title: Text('TAGS', style: theme.textTheme.labelSmall),
              ),
              for (final tag in _tagList)
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: Text(tag.name),
                  selected: _tagFilter?.id == tag.id,
                  onTap: () => _select(NotesView.all, tag: tag),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) => action == 'rename'
                        ? _renameTag(tag)
                        : _deleteTag(tag),
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'rename', child: Text('Rename')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
            ],
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out'),
              onTap: () {
                Navigator.pop(context);
                _signOut();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _NotebookChoice {
  final String? notebookId;
  const _NotebookChoice(this.notebookId);
}
