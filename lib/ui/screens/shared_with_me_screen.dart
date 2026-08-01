import 'package:flutter/material.dart';

import '../../core/network/api_exceptions.dart';
import '../../data/datasources/remote/collaboration_remote_datasource.dart';
import '../../data/models/note.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';
import 'note_editor_screen.dart';

class SharedWithMeScreen extends StatefulWidget {
  const SharedWithMeScreen({super.key});

  @override
  State<SharedWithMeScreen> createState() => _SharedWithMeScreenState();
}

class _SharedWithMeScreenState extends State<SharedWithMeScreen> {
  final _remote = CollaborationRemoteDataSource();
  late Future<List<SharedItem>> _items = _remote.sharedWithMe();

  void _retry() {
    if (!mounted) return;
    setState(() => _items = _remote.sharedWithMe());
  }

  Future<void> _leave(SharedItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Leave shared item?'),
        content: Text(
          'You will lose access to “${item.name}” unless its owner shares it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _remote.removeShare(item.shareId);
      if (!mounted) return;
      _retry();
    } catch (error) {
      if (!mounted) return;
      final message = error is ApiException
          ? error.message
          : 'Could not leave this shared item.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 22, 12),
              child: Row(
                children: [
                  CircleIconButton(
                    Icons.arrow_back_ios_new,
                    size: 32,
                    onTap: () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Shared with me',
                      style: OblixType.pageTitle(c),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<SharedItem>>(
                future: _items,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: TextButton(
                        onPressed: _retry,
                        child: const Text('Could not load. Try again'),
                      ),
                    );
                  }
                  final items = snapshot.data ?? const [];
                  if (items.isEmpty) {
                    return Center(
                      child: Text(
                        'Nothing has been shared with you yet.',
                        style: OblixType.ui(c, size: 14, color: c.inkMuted),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: c.hairline),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ListTile(
                        leading: Icon(
                          item.entityType == 'note'
                              ? Icons.description_outlined
                              : Icons.library_books_outlined,
                          color: c.inkSecondary,
                        ),
                        title: Text(item.name),
                        subtitle: Text(
                          '${item.ownerDisplayName ?? item.ownerEmail} · ${item.role}',
                        ),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'Shared item actions',
                          onSelected: (_) => _leave(item),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'leave',
                              child: Text('Leave shared item'),
                            ),
                          ],
                        ),
                        onTap: () {
                          if (item.entityType == 'note') {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => NoteEditorScreen(
                                  noteId: item.entityId,
                                  initialCollaborationRole: item.role,
                                ),
                              ),
                            );
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => _SharedNotebookScreen(
                                  item: item,
                                  remote: _remote,
                                ),
                              ),
                            );
                          }
                        },
                      );
                    },
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

class _SharedNotebookScreen extends StatelessWidget {
  final SharedItem item;
  final CollaborationRemoteDataSource remote;

  const _SharedNotebookScreen({required this.item, required this.remote});

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(item.name)),
      body: FutureBuilder<List<Note>>(
        future: remote.sharedNotebookNotes(item.entityId),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(child: Text('Could not load this notebook.'));
          }
          final notes = snapshot.data ?? const [];
          if (notes.isEmpty) {
            return Center(
              child: Text(
                'No notes in this notebook.',
                style: OblixType.ui(c, size: 14, color: c.inkMuted),
              ),
            );
          }
          return ListView.builder(
            itemCount: notes.length,
            itemBuilder: (context, index) => ListTile(
              title: Text(notes[index].title),
              subtitle: Text(
                notes[index].content,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => NoteEditorScreen(
                    noteId: notes[index].id,
                    initialCollaborationRole: item.role,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
