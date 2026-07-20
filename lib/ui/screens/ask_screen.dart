import 'dart:async';
import 'package:flutter/material.dart';
import '../../data/models/note.dart';
import '../../data/models/notebook.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../theme/oblix_theme.dart';
import '../util/formats.dart';
import '../widgets/paper.dart';
import 'note_editor_screen.dart';

/// Search across all notes (FTS with LIKE fallback) in the Ask layout:
/// accent-bordered input, "FROM YOUR NOTES" result card, TRY suggestions.
/// The conversational AI answer arrives once the backend grows an /ai/ask
/// endpoint — search is fully local and works offline today.
class AskScreen extends StatefulWidget {
  const AskScreen({super.key});

  @override
  State<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends State<AskScreen> {
  final _notes = NoteRepository();
  final _notebooks = NotebookRepository();
  final _ctrl = TextEditingController();

  Timer? _debounce;
  String _query = '';
  int _total = 0;
  List<Note> _results = const [];
  Map<String, String> _bookNames = const {};

  static const _suggestions = [
    'meeting', 'ideas', 'travel', 'recipe',
  ];

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadCounts() async {
    final all = await _notes.listNotes(archived: null);
    final books = await _notebooks.listNotebooks();
    if (!mounted) return;
    setState(() {
      _total = all.length;
      _bookNames = {for (final Notebook b in books) b.id: b.name};
    });
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final query = value.trim();
      if (!mounted) return;
      if (query.isEmpty) {
        setState(() {
          _query = '';
          _results = const [];
        });
        return;
      }
      final results = await _notes.listNotes(archived: null, search: query);
      if (!mounted) return;
      setState(() {
        _query = query;
        _results = results;
      });
    });
  }

  void _fill(String text) {
    _ctrl.text = text;
    _ctrl.selection = TextSelection.collapsed(offset: text.length);
    _onChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
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
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ask', style: OblixType.pageTitle(c)),
                  const SizedBox(height: 4),
                  Text(
                    'Search, or ask across all $_total '
                    '${_total == 1 ? 'note' : 'notes'}',
                    style: OblixType.ui(c, size: 12, color: c.inkMuted),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: c.accent, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: c.accent.withValues(alpha: 0.1),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 16, color: c.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _ctrl,
                        autofocus: true,
                        onChanged: _onChanged,
                        style: OblixType.ui(c, size: 14.5),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'What are you looking for?',
                          hintStyle: OblixType.ui(c,
                              size: 14.5, color: c.inkMuted),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_query.isNotEmpty)
              _results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(20, 40, 20, 0),
                      child: Center(
                        child: Text(
                          'Nothing matches "$_query".',
                          style:
                              OblixType.ui(c, size: 14, color: c.inkMuted),
                        ),
                      ),
                    )
                  : PaperCard(
                      margin: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.auto_awesome,
                                  size: 11, color: c.accent),
                              const SizedBox(width: 6),
                              Text('FROM YOUR NOTES',
                                  style: OblixType.eyebrow(c,
                                      color: c.accent)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          for (var i = 0; i < _results.length; i++) ...[
                            if (i > 0)
                              Divider(height: 1, color: c.hairline),
                            _ResultRow(
                              note: _results[i],
                              bookName:
                                  _bookNames[_results[i].notebookId],
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => NoteEditorScreen(
                                      noteId: _results[i].id),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
            else ...[
              const SectionEyebrow('Try',
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 8)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in _suggestions)
                      Material(
                        color: Colors.transparent,
                        shape: StadiumBorder(
                          side: BorderSide(
                              color: c.ink.withValues(alpha: 0.14)),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => _fill(s),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            child: Text(
                              s,
                              style: OblixType.ui(c,
                                  size: 12.5, color: c.avatarInk),
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
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final Note note;
  final String? bookName;
  final VoidCallback onTap;

  const _ResultRow({
    required this.note,
    required this.bookName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final meta =
        [?bookName, Formats.relative(note.updatedAt)].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Icon(Icons.description_outlined, size: 14, color: c.inkMuted),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                note.title.isEmpty ? 'Untitled' : note.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    OblixType.ui(c, size: 13, weight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Text(meta, style: OblixType.meta(c)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 14, color: c.outline),
          ],
        ),
      ),
    );
  }
}
