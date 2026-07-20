import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/models/note.dart';
import '../../data/models/notebook.dart';
import '../../data/models/tag.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../../data/repositories/tag_repository.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';
import 'notebook_detail_screen.dart';

/// The Books tab: notebooks with note counts, a New pill, and tag chips.
class NotebooksScreen extends StatefulWidget {
  const NotebooksScreen({super.key});

  @override
  State<NotebooksScreen> createState() => _NotebooksScreenState();
}

class _NotebooksScreenState extends State<NotebooksScreen> {
  final _notes = NoteRepository();
  final _notebooks = NotebookRepository();
  final _tags = TagRepository();

  List<Notebook> _books = const [];
  List<Tag> _tagList = const [];
  Map<String, int> _bookCounts = const {};
  Map<String, int> _tagCounts = const {};
  int _noteCount = 0;
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
    final books = await _notebooks.listNotebooks();
    final tags = await _tags.listTags();
    final notes = await _notes.listNotes(archived: null);
    if (!mounted) return;

    final bookCounts = <String, int>{};
    final tagCounts = <String, int>{};
    for (final Note note in notes) {
      final id = note.notebookId;
      if (id != null) bookCounts[id] = (bookCounts[id] ?? 0) + 1;
      for (final tag in note.tagNames) {
        tagCounts[tag] = (tagCounts[tag] ?? 0) + 1;
      }
    }
    setState(() {
      _books = books;
      _tagList = tags;
      _bookCounts = bookCounts;
      _tagCounts = tagCounts;
      _noteCount = notes.length;
    });
  }

  Future<void> _createNotebook() async {
    final c = OblixColors.of(context);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New notebook'),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: OblixType.ui(c, size: 15),
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await _notebooks.createNotebook(name: name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Notebooks', style: OblixType.pageTitle(c)),
                      const SizedBox(height: 4),
                      Text(
                        '${_books.length} '
                        '${_books.length == 1 ? 'notebook' : 'notebooks'}'
                        ' · $_noteCount ${_noteCount == 1 ? 'note' : 'notes'}',
                        style: OblixType.ui(c, size: 12, color: c.inkMuted),
                      ),
                    ],
                  ),
                ),
                AccentPill(
                  label: 'New',
                  icon: Icons.add,
                  onTap: _createNotebook,
                ),
              ],
            ),
          ),
          if (_books.isNotEmpty)
            PaperCard(
              margin: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Column(
                children: [
                  for (var i = 0; i < _books.length; i++) ...[
                    if (i > 0) Divider(height: 1, color: c.hairline),
                    _NotebookRow(
                      notebook: _books[i],
                      count: _bookCounts[_books[i].id] ?? 0,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              NotebookDetailScreen(notebook: _books[i]),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 20),
              child: Center(
                child: Text(
                  'No notebooks yet — tap New to make one.',
                  style: OblixType.ui(c, size: 14, color: c.inkMuted),
                ),
              ),
            ),
          if (_tagList.isNotEmpty) ...[
            const SectionEyebrow('Tags',
                padding: EdgeInsets.fromLTRB(20, 22, 20, 8)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in _tagList)
                    Material(
                      color: Colors.transparent,
                      shape: StadiumBorder(
                        side: BorderSide(
                            color: c.ink.withValues(alpha: 0.14)),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => TagNotesScreen(tag: tag),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 13, vertical: 7),
                          child: Text.rich(
                            TextSpan(
                              text: '#${tag.name} ',
                              style: OblixType.ui(c,
                                  size: 12.5, color: c.avatarInk),
                              children: [
                                TextSpan(
                                  text: '${_tagCounts[tag.name] ?? 0}',
                                  style: OblixType.ui(c,
                                      size: 12.5, color: c.inkFaint),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NotebookRow extends StatelessWidget {
  final Notebook notebook;
  final int count;
  final VoidCallback onTap;

  const _NotebookRow({
    required this.notebook,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(9),
              ),
              child:
                  Icon(Icons.menu_book_outlined, size: 16, color: c.avatarInk),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                notebook.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: OblixType.serif,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.ink,
                ),
              ),
            ),
            Text('$count', style: OblixType.ui(c, size: 12, color: c.inkFaint)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 18, color: c.outline),
          ],
        ),
      ),
    );
  }
}
