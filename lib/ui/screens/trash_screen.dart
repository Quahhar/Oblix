import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/config/api_config.dart';
import '../../data/models/note.dart';
import '../../data/repositories/note_repository.dart';
import '../theme/oblix_theme.dart';
import '../util/formats.dart';
import '../widgets/paper.dart';

/// Deleted notes with their 30-day recovery countdown. Restore per row;
/// "Empty" purges everything the server already knows about.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
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
    final notes = await _notes.listNotes(archived: null, deleted: true);
    if (!mounted) return;
    setState(() => _items = notes);
  }

  Future<void> _empty() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Empty trash?'),
        content: const Text(
          'These notes are removed from this device for good. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Empty'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await _notes.emptyTrash();
  }

  /// Days left before the tombstone is purged (retention runs from the delete).
  int _daysLeft(Note note) {
    final elapsed = DateTime.now().toUtc().difference(note.updatedAt.toUtc());
    final left = ApiConfig.tombstoneRetention.inDays - elapsed.inDays;
    return left < 0 ? 0 : left;
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
                  if (_items.isNotEmpty)
                    TextButton(
                      onPressed: _empty,
                      child: Text(
                        'Empty',
                        style: OblixType.ui(c,
                            size: 13.5,
                            weight: FontWeight.w600,
                            color: c.danger),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
              child: Text('Trash', style: OblixType.pageTitle(c)),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(22, 8, 22, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: c.ink.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule, size: 15, color: c.inkMuted),
                  const SizedBox(width: 8),
                  Text(
                    'Items are deleted forever after '
                    '${ApiConfig.tombstoneRetention.inDays} days',
                    style: OblixType.ui(c, size: 12.5, color: c.inkSecondary),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Text(
                        'Trash is empty.',
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
                                child: Icon(Icons.description_outlined,
                                    size: 17, color: c.inkMuted),
                              ),
                              const SizedBox(width: 13),
                              Expanded(
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
                                      style: OblixType.ui(c,
                                          size: 15,
                                          weight: FontWeight.w600,
                                          color: c.avatarInk),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Deleted ${Formats.relative(note.updatedAt).toLowerCase()}'
                                      ' · ${_daysLeft(note)} left',
                                      style: OblixType.meta(c),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: Icon(Icons.restore,
                                    size: 18, color: c.accent),
                                tooltip: 'Restore',
                                onPressed: () async {
                                  await _notes.restoreNote(note.id);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context)
                                    ..hideCurrentSnackBar()
                                    ..showSnackBar(const SnackBar(
                                        content: Text('Note restored')));
                                },
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
