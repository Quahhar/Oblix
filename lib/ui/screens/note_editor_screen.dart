import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../../data/models/attachment.dart';
import '../../data/models/note.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../../data/repositories/tag_repository.dart';
import '../../data/repositories/task_repository.dart';
import '../sheets/ai_actions_sheet.dart';
import '../theme/oblix_theme.dart';
import '../util/formats.dart';
import '../widgets/paper.dart';

/// Full-screen note editor with debounced autosave. A brand-new note is only
/// created once something is typed (no empty notes from an accidental tap);
/// after that every pause persists locally and syncs in the background.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, this.noteId, this.initialNotebookId});

  /// Existing note to edit; null starts a new draft.
  final String? noteId;

  /// Notebook a new note is filed into (e.g. created from a notebook screen).
  final String? initialNotebookId;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  final _repo = NoteRepository();
  final _notebooks = NotebookRepository();
  final _tags = TagRepository();
  final _tasks = TaskRepository();
  final _attachmentRepo = AttachmentRepository();

  final _title = TextEditingController();
  final _content = TextEditingController();

  Note? _note;
  String? _notebookName;
  List<Attachment> _attachments = const [];
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
        _attachments = await _attachmentRepo.listForNote(note.id);
      }
    }
    await _loadNotebookName();
    // Attach listeners only after the initial text is in, so loading a note
    // doesn't count as an edit.
    _title.addListener(_onEdited);
    _content.addListener(_onEdited);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadNotebookName() async {
    final id = _note?.notebookId ?? widget.initialNotebookId;
    if (id == null) {
      _notebookName = null;
      return;
    }
    final books = await _notebooks.listNotebooks();
    for (final b in books) {
      if (b.id == id) {
        _notebookName = b.name;
        return;
      }
    }
    _notebookName = null;
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
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      await _save();
      if (mounted) setState(() {}); // refresh the meta line
    });
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
  Future<void> _withSavedNote(Future<void> Function(Note note) action) async {
    _debounce?.cancel();
    await _save();
    final note = _note;
    if (note != null) {
      await action(note);
    } else if (mounted) {
      _toast('Write something first');
    }
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

  Future<void> _share() => _withSavedNote((note) async {
        final body = note.title.isEmpty || note.title == 'Untitled'
            ? note.content
            : '${note.title}\n\n${note.content}';
        await SharePlus.instance.share(ShareParams(text: body));
      });

  Future<void> _aiActions() => _withSavedNote((note) async {
        final summary = await showAiActionsSheet(context, note);
        if (summary == null || summary.isEmpty) return;
        // Insert the recap at the top of the body, leaving the original text.
        _content.text = '$summary\n\n${_content.text}';
        _onEdited();
      });

  /// Turn the current note into a task (the note's title seeds it).
  Future<void> _createTask() => _withSavedNote((note) async {
        await _tasks.createTask(
          title: note.title == 'Untitled' ? 'Follow up' : note.title,
          noteId: note.id,
        );
        if (mounted) _toast('Task added');
      });

  Future<void> _moveToNotebook() => _withSavedNote((note) async {
        final notebooks = await _notebooks.listNotebooks();
        if (!mounted) return;
        final choice = await showModalBottomSheet<List<String?>>(
          context: context,
          builder: (context) {
            final c = OblixColors.of(context);
            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const SheetGrabHandle(),
                  ListTile(
                    leading:
                        Icon(Icons.folder_off_outlined, color: c.inkSecondary),
                    title: Text('No notebook', style: OblixType.ui(c, size: 15)),
                    selected: note.notebookId == null,
                    onTap: () => Navigator.pop(context, [null]),
                  ),
                  for (final nb in notebooks)
                    ListTile(
                      leading: Icon(Icons.menu_book_outlined,
                          color: c.inkSecondary),
                      title: Text(nb.name, style: OblixType.ui(c, size: 15)),
                      selected: nb.id == note.notebookId,
                      onTap: () => Navigator.pop(context, [nb.id]),
                    ),
                ],
              ),
            );
          },
        );
        if (choice != null) {
          _note = await _repo.moveToNotebook(note.id, choice.single);
          await _loadNotebookName();
          if (mounted) setState(() {});
        }
      });

  Future<void> _refreshAttachments() async {
    final note = _note;
    if (note == null) return;
    final items = await _attachmentRepo.listForNote(note.id);
    if (mounted) setState(() => _attachments = items);
  }

  /// Attach a picked file. Routed through [_withSavedNote] so the note exists
  /// (attachments key off a real note id).
  Future<void> _addAttachment() => _withSavedNote((note) async {
        final picked = await FilePicker.pickFiles(withData: true);
        if (picked == null || picked.files.isEmpty) return;
        final file = picked.files.first;
        final bytes = file.bytes;
        if (bytes == null) {
          _toast("Couldn't read that file");
          return;
        }
        await _attachmentRepo.attach(
          noteId: note.id,
          bytes: bytes,
          originalName: file.name,
        );
        await _refreshAttachments();
      });

  Future<void> _openAttachment(Attachment a) async {
    try {
      if (a.isImage) {
        final bytes = await _attachmentRepo.bytesFor(a);
        if (!mounted || bytes == null) {
          if (mounted) _toast('Not available offline yet');
          return;
        }
        await showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            child: InteractiveViewer(
              child: Image.memory(Uint8List.fromList(bytes)),
            ),
          ),
        );
      } else {
        final path = await _attachmentRepo.ensureLocalPath(a);
        if (!mounted) return;
        if (path == null) {
          _toast('Not available offline yet');
          return;
        }
        await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
      }
    } catch (_) {
      if (mounted) _toast("Couldn't open attachment");
    }
  }

  Future<void> _removeAttachment(Attachment a) async {
    await _attachmentRepo.delete(a);
    await _refreshAttachments();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

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
        // Make sure every name exists as a Tag entity so it shows up on the
        // Books tab immediately (the server would create it on sync anyway).
        final known = (await _tags.listTags()).map((t) => t.name).toSet();
        for (final name in names) {
          if (!known.contains(name)) await _tags.createTag(name);
        }
        if (mounted) setState(() {});
      });

  String get _metaLine {
    final note = _note;
    final parts = <String>[
      if (_notebookName != null) 'In $_notebookName',
      if (note != null)
        'Edited ${Formats.time(note.updatedAt)}'
      else
        'Not saved yet',
      Formats.wordCount(_content.text),
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final note = _note;
    final pinned = note?.isPinned ?? false;

    return Scaffold(
      backgroundColor: c.surface,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: [
                  // Top bar: back pill (carrying the notebook name) + actions.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        Material(
                          color: c.bg,
                          shape: StadiumBorder(
                              side: BorderSide(color: c.hairline)),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () => Navigator.pop(context),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.arrow_back_ios_new,
                                      size: 12, color: c.ink),
                                  const SizedBox(width: 6),
                                  Text(
                                    _notebookName ?? 'Notes',
                                    style: OblixType.ui(c,
                                        size: 13, weight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        CircleIconButton(
                          pinned ? Icons.push_pin : Icons.push_pin_outlined,
                          tooltip: pinned ? 'Unpin' : 'Pin',
                          onTap: _togglePin,
                        ),
                        const SizedBox(width: 8),
                        CircleIconButton(
                          Icons.ios_share,
                          tooltip: 'Share',
                          onTap: _share,
                        ),
                        const SizedBox(width: 8),
                        _OverflowButton(
                          isArchived: note?.isArchived ?? false,
                          onMove: _moveToNotebook,
                          onTags: _editTags,
                          onArchive: _toggleArchive,
                          onDelete: _delete,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 26, 24, 12),
                      children: [
                        TextField(
                          controller: _title,
                          textInputAction: TextInputAction.next,
                          style: OblixType.editorTitle(c),
                          decoration: InputDecoration(
                            hintText: 'Title',
                            hintStyle: OblixType.editorTitle(c)
                                .copyWith(color: c.inkFaint),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(_metaLine, style: OblixType.meta(c)),
                        if (note != null && note.tagNames.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final tag in note.tagNames)
                                GestureDetector(
                                  onTap: _editTags,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 9, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: c.accentSoft,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '#$tag',
                                      style: OblixType.ui(c,
                                          size: 12,
                                          weight: FontWeight.w600,
                                          color: c.accentDeep),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                        if (_attachments.isNotEmpty) _attachmentsStrip(),
                        const SizedBox(height: 18),
                        TextField(
                          controller: _content,
                          maxLines: null,
                          keyboardType: TextInputType.multiline,
                          style: OblixType.noteBody(c),
                          decoration: InputDecoration(
                            hintText: 'Start writing…',
                            hintStyle: OblixType.noteBody(c)
                                .copyWith(color: c.inkFaint),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Bottom toolbar.
                  Container(
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.hairline)),
                    ),
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
                    child: Row(
                      children: [
                        _ToolbarButton(
                          icon: Icons.attach_file,
                          tooltip: 'Attach file',
                          onTap: _addAttachment,
                        ),
                        const SizedBox(width: 22),
                        _ToolbarButton(
                          icon: Icons.check_circle_outline,
                          tooltip: 'Make a task',
                          onTap: _createTask,
                        ),
                        const SizedBox(width: 22),
                        _ToolbarButton(
                          icon: Icons.sell_outlined,
                          tooltip: 'Edit tags',
                          onTap: _editTags,
                        ),
                        const Spacer(),
                        _ToolbarButton(
                          icon: Icons.auto_awesome,
                          tooltip: 'Ask Oblix',
                          color: c.accent,
                          onTap: _aiActions,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _attachmentsStrip() {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _attachments.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, i) {
            final a = _attachments[i];
            return _AttachmentCard(
              attachment: a,
              onOpen: () => _openAttachment(a),
              onRemove: () => _removeAttachment(a),
            );
          },
        ),
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color? color;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Icon(icon, size: 19, color: color ?? c.inkSecondary),
      ),
    );
  }
}

class _OverflowButton extends StatelessWidget {
  final bool isArchived;
  final VoidCallback onMove;
  final VoidCallback onTags;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  const _OverflowButton({
    required this.isArchived,
    required this.onMove,
    required this.onTags,
    required this.onArchive,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return Material(
      color: c.bg,
      shape: CircleBorder(side: BorderSide(color: c.hairline)),
      clipBehavior: Clip.antiAlias,
      child: PopupMenuButton<String>(
        icon: Icon(Icons.more_horiz, size: 17, color: c.ink),
        tooltip: 'More',
        onSelected: (action) => switch (action) {
          'move' => onMove(),
          'tags' => onTags(),
          'archive' => onArchive(),
          'delete' => onDelete(),
          _ => null,
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'move', child: Text('Move to notebook')),
          const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
          PopupMenuItem(
            value: 'archive',
            child: Text(isArchived ? 'Unarchive' : 'Archive'),
          ),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

/// A compact card for one attachment in the editor's horizontal strip: a
/// thumbnail (image preview or type icon), name, size, upload state, and a
/// remove control.
class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.attachment,
    required this.onOpen,
    required this.onRemove,
  });

  final Attachment attachment;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    final c = OblixColors.of(context);
    return SizedBox(
      width: 186,
      child: PaperCard(
        padding: const EdgeInsets.all(8),
        onTap: onOpen,
        child: Row(
          children: [
            _thumb(context),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.originalName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OblixType.ui(c, size: 12),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(
                        a.isUploaded
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_upload_outlined,
                        size: 12,
                        color: c.inkFaint,
                      ),
                      const SizedBox(width: 3),
                      Text(_fmtSize(a.sizeBytes), style: OblixType.meta(c)),
                    ],
                  ),
                ],
              ),
            ),
            InkResponse(
              onTap: onRemove,
              radius: 14,
              child: Icon(Icons.close, size: 15, color: c.inkMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _thumb(BuildContext context) {
    final a = attachment;
    if (a.isImage && a.hasLocalBytes) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(a.localPath!),
          width: 42,
          height: 42,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _icon(context),
        ),
      );
    }
    return _icon(context);
  }

  Widget _icon(BuildContext context) {
    final a = attachment;
    final c = OblixColors.of(context);
    final IconData icon;
    if (a.isImage) {
      icon = Icons.image_outlined;
    } else if (a.mimeType == 'application/pdf') {
      icon = Icons.picture_as_pdf_outlined;
    } else if (a.mimeType.startsWith('audio/')) {
      icon = Icons.audiotrack_outlined;
    } else if (a.mimeType.startsWith('video/')) {
      icon = Icons.movie_outlined;
    } else if (a.mimeType.startsWith('text/')) {
      icon = Icons.description_outlined;
    } else {
      icon = Icons.insert_drive_file_outlined;
    }
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, size: 20, color: c.avatarInk),
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
