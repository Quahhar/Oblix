import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/app_bootstrap.dart';
import '../../data/models/note.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../../core/native/oblix_core.dart';
import '../sheets/note_actions_sheet.dart';
import '../theme/oblix_theme.dart';
import '../util/formats.dart';
import '../widgets/note_timeline.dart';
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
      ..showSnackBar(
        const SnackBar(content: Text('Sync failed, changes are kept locally')),
      );
  }

  void _openEditor({String? noteId}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: noteId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pinned = _items.where((n) => n.isPinned).toList();
    final rest = _items.where((n) => !n.isPinned).toList();

    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: _sync,
        child: ValueListenableBuilder<bool>(
          valueListenable: AppBootstrap.scheduler.firstSyncSettled,
          builder: (context, firstSyncSettled, _) {
            // An empty local database only becomes news once this session's
            // first sync has been and gone. Straight after a sign-in it is
            // empty because the notes are still coming down, and showing "A
            // clean page." for that half second makes a full account look
            // brand new. Placeholders under the real header carry the wait
            // instead, and the notes drop in beneath a header that never moved.
            if (!_loaded || (_items.isEmpty && !firstSyncSettled)) {
              return const _LoadingList();
            }
            if (_items.isEmpty) {
              return _EmptyState(onWrite: () => _openEditor());
            }
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 116),
              children: [
                const _TimelineHeader(),
                if (pinned.isNotEmpty) ...[
                  const SectionEyebrow(
                    'Pinned',
                    padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
                  ),
                  _PinnedGrid(
                    notes: pinned,
                    notebookNames: _notebookNames,
                    onOpen: (n) => _openEditor(noteId: n.id),
                  ),
                ],
                ...buildGroupedSections(
                  context,
                  notes: rest,
                  onOpen: (note) => _openEditor(noteId: note.id),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Date eyebrow, settings gear, title, and the search-or-ask pill.
///
/// Shared by the loaded list and the loading placeholder so the two agree to
/// the pixel and nothing jumps when the notes arrive.
class _TimelineHeader extends StatelessWidget {
  const _TimelineHeader();

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                Formats.dateEyebrow(DateTime.now()),
                style: OblixType.eyebrow(c),
              ),
              IconButton(
                icon: Icon(
                  Icons.settings_outlined,
                  size: 22,
                  color: c.inkMuted,
                ),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
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
          child: GlassPill(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AskScreen()),
            ),
            child: Row(
              children: [
                Icon(Icons.search, size: 17, color: c.inkMuted),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    'Search or ask your notes…',
                    style: OblixType.ui(c, size: 14, color: c.inkMuted),
                  ),
                ),
                Icon(Icons.mic_none, size: 17, color: c.inkMuted),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The header plus a card of blank rows, shown while the first note load — and,
/// on a fresh sign-in, the first sync — is still in flight.
class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 116),
      children: [
        const _TimelineHeader(),
        const SectionEyebrow(
          'Loading',
          padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
        ),
        _Pulse(
          child: PaperCard(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: OblixColors.of(context).hairline),
                  const _SkeletonRow(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One placeholder note row: a title bar and a shorter snippet bar, laid out to
/// the same rhythm as [NoteTimelineRow].
class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [bar(0.52, 12), const SizedBox(height: 9), bar(0.78, 10)],
      ),
    );
  }
}

/// Breathes its child's opacity so the placeholders read as "loading" rather
/// than as content that failed to draw.
class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});

  final Widget child;

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 850),
    vsync: this,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1).animate(
        CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
      ),
      child: widget.child,
    );
  }
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
      rows.add(
        Row(
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
        ),
      );
      if (i + 2 < notes.length) rows.add(const SizedBox(height: 10));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(children: rows),
    );
  }

  Widget _card(BuildContext context, OblixColors c, Note note) {
    final snippet = noteSnippet(note.content);
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
              Text(
                Formats.dateEyebrow(DateTime.now()),
                style: OblixType.eyebrow(c),
              ),
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
                          child: Icon(
                            Icons.description_outlined,
                            size: 38,
                            color: c.avatarBg,
                          ),
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
                    'Tap the button below to jot a thought. Audio and scans '
                    'are on the way.',
                    textAlign: TextAlign.center,
                    style: OblixType.ui(c, size: 14, color: c.inkMuted),
                  ),
                ),
                const SizedBox(height: 22),
                GlassPill(
                  onTap: onWrite,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.notes, size: 13, color: c.avatarInk),
                      const SizedBox(width: 6),
                      Text(
                        'Write',
                        style: OblixType.ui(
                          c,
                          size: 13,
                          weight: FontWeight.w600,
                          color: c.avatarInk,
                        ),
                      ),
                    ],
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
