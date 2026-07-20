import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/app_bootstrap.dart';
import '../../core/auth/profile_cache.dart';
import '../../data/models/note.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../sheets/note_actions_sheet.dart';
import '../theme/oblix_theme.dart';
import '../util/formats.dart';
import '../widgets/paper.dart';
import 'ask_screen.dart';
import 'note_editor_screen.dart';
import 'settings_screen.dart';

/// The Notes tab: date header, serif title, search-or-ask pill, PINNED grid,
/// then the timeline grouped by day. First-run shows the "A clean page."
/// empty state.
class HomeTimelineScreen extends StatefulWidget {
  const HomeTimelineScreen({super.key});

  @override
  State<HomeTimelineScreen> createState() => _HomeTimelineScreenState();
}

class _HomeTimelineScreenState extends State<HomeTimelineScreen> {
  final _notes = NoteRepository();
  final _notebooks = NotebookRepository();

  List<Note> _items = const [];
  Map<String, String> _notebookNames = const {};
  bool _loaded = false;
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
    final notes = await _notes.listNotes();
    final books = await _notebooks.listNotebooks();
    if (!mounted) return;
    setState(() {
      _items = notes;
      _notebookNames = {for (final b in books) b.id: b.name};
      _loaded = true;
    });
  }

  Future<void> _sync() async {
    final result = await AppBootstrap.scheduler.syncNow();
    if (!mounted || result.skipped || result.success) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
          content: Text('Sync failed — changes are kept locally')));
  }

  void _openEditor({String? noteId}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: noteId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final pinned = _items.where((n) => n.isPinned).toList();
    final rest = _items.where((n) => !n.isPinned).toList();

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: _sync,
        child: _loaded && _items.isEmpty
            ? _EmptyState(onWrite: () => _openEditor())
            : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(Formats.dateEyebrow(DateTime.now()),
                            style: OblixType.eyebrow(c)),
                        ValueListenableBuilder<String?>(
                          valueListenable: ProfileCache.instance.name,
                          builder: (context, name, _) => OblixAvatar(
                            name: name,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const SettingsScreen()),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                    child: Text('Notes', style: OblixType.pageTitle(c)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: Material(
                      color: c.surface,
                      shape: StadiumBorder(side: BorderSide(color: c.hairline)),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const AskScreen()),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 11),
                          child: Row(
                            children: [
                              Icon(Icons.search, size: 17, color: c.inkMuted),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  'Search or ask your notes…',
                                  style: OblixType.ui(c,
                                      size: 14, color: c.inkMuted),
                                ),
                              ),
                              Icon(Icons.mic_none, size: 17, color: c.inkMuted),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (pinned.isNotEmpty) ...[
                    const SectionEyebrow('Pinned',
                        padding: EdgeInsets.fromLTRB(20, 20, 20, 8)),
                    _PinnedGrid(
                      notes: pinned,
                      notebookNames: _notebookNames,
                      onOpen: (n) => _openEditor(noteId: n.id),
                    ),
                  ],
                  for (final group in _groupByDay(rest)) ...[
                    SectionEyebrow(group.label,
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8)),
                    PaperCard(
                      margin: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        children: [
                          for (var i = 0; i < group.notes.length; i++) ...[
                            if (i > 0) Divider(height: 1, color: c.hairline),
                            _TimelineRow(
                              note: group.notes[i],
                              onTap: () =>
                                  _openEditor(noteId: group.notes[i].id),
                              onLongPress: () => showNoteActionsSheet(
                                  context, group.notes[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  List<_DayGroup> _groupByDay(List<Note> notes) {
    final groups = <String, _DayGroup>{};
    for (final note in notes) {
      final label = Formats.dayGroup(note.updatedAt);
      groups.putIfAbsent(label, () => _DayGroup(label)).notes.add(note);
    }
    return groups.values.toList();
  }
}

class _DayGroup {
  final String label;
  final List<Note> notes = [];
  _DayGroup(this.label);
}

class _PinnedGrid extends StatelessWidget {
  final List<Note> notes;
  final Map<String, String> notebookNames;
  final void Function(Note) onOpen;

  const _PinnedGrid({
    required this.notes,
    required this.notebookNames,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < notes.length; i += 2) {
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _card(context, c, notes[i])),
          const SizedBox(width: 10),
          Expanded(
            child: i + 1 < notes.length
                ? _card(context, c, notes[i + 1])
                : const SizedBox(),
          ),
        ],
      ));
      if (i + 2 < notes.length) rows.add(const SizedBox(height: 10));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(children: rows),
    );
  }

  Widget _card(BuildContext context, OblixColors c, Note note) {
    final snippet = note.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    final book = notebookNames[note.notebookId];
    final meta = [?book, Formats.relative(note.updatedAt)].join(' · ');
    return PaperCard(
      padding: const EdgeInsets.all(14),
      onTap: () => onOpen(note),
      onLongPress: () => showNoteActionsSheet(context, note),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            note.title.isEmpty ? 'Untitled' : note.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: OblixType.cardTitle(c),
          ),
          if (snippet.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              snippet,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: OblixType.snippet(c),
            ),
          ],
          const SizedBox(height: 9),
          Text(meta, style: OblixType.meta(c)),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final Note note;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _TimelineRow({
    required this.note,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final snippet = note.content.replaceAll(RegExp(r'\s+'), ' ').trim();
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
                Text(Formats.time(note.updatedAt), style: OblixType.meta(c)),
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
                          horizontal: 8, vertical: 1),
                      decoration: BoxDecoration(
                        color: c.accentSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text('#$tag',
                          style: OblixType.ui(c,
                              size: 11.5, color: c.accentDeep)),
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

class _EmptyState extends StatelessWidget {
  final VoidCallback onWrite;
  const _EmptyState({required this.onWrite});

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(Formats.dateEyebrow(DateTime.now()),
                  style: OblixType.eyebrow(c)),
              const SizedBox(height: 5),
              Text('Notes', style: OblixType.pageTitle(c)),
            ],
          ),
        ),
        SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.55,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 104,
                  height: 104,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: Transform.rotate(
                          angle: -0.12,
                          child: Container(
                            decoration: BoxDecoration(
                              color: c.surface,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: c.hairline),
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: c.hairline),
                          ),
                          child: Icon(Icons.description_outlined,
                              size: 38, color: c.avatarBg),
                        ),
                      ),
                      Positioned(
                        right: -8,
                        bottom: -8,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: c.accent.withValues(alpha: 0.3),
                                blurRadius: 14,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Icon(Icons.add, size: 18, color: c.onAccent),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Text(
                  'A clean page.',
                  style: TextStyle(
                    fontFamily: OblixType.serif,
                    fontSize: 23,
                    fontWeight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 9),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 250),
                  child: Text(
                    'Tap the button below to jot a thought — audio and scans '
                    'are on the way.',
                    textAlign: TextAlign.center,
                    style: OblixType.ui(c, size: 14, color: c.inkMuted),
                  ),
                ),
                const SizedBox(height: 22),
                Material(
                  color: c.surface,
                  shape: StadiumBorder(side: BorderSide(color: c.hairline)),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onWrite,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.notes, size: 13, color: c.avatarInk),
                          const SizedBox(width: 6),
                          Text('Write',
                              style: OblixType.ui(c,
                                  size: 13,
                                  weight: FontWeight.w600,
                                  color: c.avatarInk)),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
