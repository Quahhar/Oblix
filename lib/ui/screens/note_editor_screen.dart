import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/models/attachment.dart';
import '../../data/models/note.dart';
import '../../data/datasources/remote/collaboration_remote_datasource.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/notebook_repository.dart';
import '../../data/repositories/tag_repository.dart';
import '../../data/repositories/task_repository.dart';
import '../../domain/services/import_export_service.dart';
import '../../domain/services/collaboration_session.dart';
import '../../core/native/oblix_core.dart';
import '../sheets/ai_actions_sheet.dart';
import '../sheets/manage_access_sheet.dart';
import '../theme/oblix_theme.dart';
import '../util/formats.dart';
import '../widgets/paper.dart';

/// Full-screen note editor with debounced autosave. A brand-new note is only
/// created once something is typed (no empty notes from an accidental tap);
/// after that every pause persists locally and syncs in the background.
class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({
    super.key,
    this.noteId,
    this.initialNotebookId,
    this.initialCollaborationRole,
  });

  /// Existing note to edit; null starts a new draft.
  final String? noteId;

  /// Notebook a new note is filed into (e.g. created from a notebook screen).
  final String? initialNotebookId;

  /// Supplied when opening from Shared with me, so owner-only controls never
  /// flash before the authenticated WebSocket snapshot arrives.
  final String? initialCollaborationRole;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  final _repo = NoteRepository();
  final _notebooks = NotebookRepository();
  final _tags = TagRepository();
  final _tasks = TaskRepository();
  final _attachmentRepo = AttachmentRepository();
  final _collaborationRemote = CollaborationRemoteDataSource();

  final _title = TextEditingController();
  final _content = TextEditingController();

  Note? _note;
  String? _notebookName;
  List<Attachment> _attachments = const [];
  bool _loading = true;
  bool _dirty = false;
  bool _saving = false;
  Timer? _debounce;
  Timer? _collaborationReadyTimer;
  CollaborationSession? _collaboration;
  bool _collaborationStarting = false;
  bool _applyingRemote = false;
  bool _disposed = false;
  bool _listenersAttached = false;
  bool _remoteShared = false;
  String? _loadError;
  String? _appliedSnapshotEpoch;
  int _appliedSnapshotRevision = -1;
  String? _latestCanonicalTitle;
  String? _latestCanonicalContent;
  String _lastTitleText = '';
  String _lastContentText = '';
  String _collaborationRole = 'owner';
  final Set<int> _collaborationTitleFallbackSeqs = <int>{};
  final Set<int> _collaborationContentFallbackSeqs = <int>{};
  void Function()? _releaseCollaborationProtection;
  Completer<void>? _saveCompletion;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.noteId != null) {
      var note = await _repo.getNote(widget.noteId!);
      if (_disposed) return;
      if (note == null) {
        try {
          note = await _collaborationRemote.getNote(widget.noteId!);
          _remoteShared = true;
          _collaborationRole = widget.initialCollaborationRole ?? 'viewer';
        } catch (_) {
          _loadError = 'This note is unavailable or your access was removed.';
        }
      }
      if (_disposed) return;
      if (note != null) {
        _note = note;
        _applyingRemote = true;
        try {
          _title.text = note.title == 'Untitled' ? '' : note.title;
          _content.text = note.content;
        } finally {
          _applyingRemote = false;
        }
        if (!_remoteShared) {
          _attachments = await _attachmentRepo.listForNote(note.id);
        }
      }
    }
    if (_disposed) return;
    await _loadNotebookName();
    if (_disposed) return;
    _lastTitleText = _title.text;
    _lastContentText = _content.text;
    // Attach listeners only after the initial text is in, so loading a note
    // doesn't count as an edit.
    if (!_listenersAttached) {
      _title.addListener(_onTitleChanged);
      _content.addListener(_onContentChanged);
      _listenersAttached = true;
    }
    final note = _note;
    if (note != null) {
      // Owners connect even while a note is private. This keeps the same OT
      // session alive if the note is shared later or moved into a shared
      // notebook, instead of briefly falling back to whole-document sync.
      unawaited(_ensureCollaboration(note.id));
    }
    if (!_disposed && mounted) setState(() => _loading = false);
  }

  Future<void> _retryLoad() async {
    if (_loading) return;
    final previous = _collaboration;
    final fallbackNoteId = _isOwner ? _note?.id : null;
    _collaboration = null;
    if (previous != null) {
      await _drainCollaboration(previous, fallbackNoteId: fallbackNoteId);
    } else {
      _releaseCollaborationProtection?.call();
      _releaseCollaborationProtection = null;
    }
    if (_disposed || !mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
      _note = null;
      _remoteShared = false;
      _collaborationRole = widget.initialCollaborationRole ?? 'owner';
    });
    await _load();
  }

  Future<void> _ensureCollaboration(String noteId) async {
    if (_disposed || _collaboration != null || _collaborationStarting) return;
    // Capture the editor before the very first await. Comparing it with the
    // last locally persisted row also detects typing which happened just
    // before this readiness check began.
    final titleBeforeStartup = _title.text;
    final contentBeforeStartup = _content.text;
    final noteBeforeStartup = _note;
    final preserveTitleBeforeStartup =
        noteBeforeStartup != null &&
        titleBeforeStartup !=
            (noteBeforeStartup.title == 'Untitled'
                ? ''
                : noteBeforeStartup.title);
    final preserveContentBeforeStartup =
        noteBeforeStartup != null &&
        contentBeforeStartup != noteBeforeStartup.content;
    _collaborationStarting = true;
    try {
      // A locally created note must reach the server before live protection
      // excludes it from ordinary sync. Keep checking while its durable create
      // row remains in the outbox.
      if (!_remoteShared && await _repo.hasPendingCreate(noteId)) {
        _scheduleCollaborationWhenReady(noteId);
        return;
      }
      _collaborationReadyTimer?.cancel();
      _collaborationReadyTimer = null;
      await _startCollaboration(
        noteId,
        titleBeforeStartup: titleBeforeStartup,
        contentBeforeStartup: contentBeforeStartup,
        preserveTitleBeforeStartup: preserveTitleBeforeStartup,
        preserveContentBeforeStartup: preserveContentBeforeStartup,
      );
    } catch (_) {
      _scheduleCollaborationWhenReady(noteId);
    } finally {
      _collaborationStarting = false;
    }
  }

  void _scheduleCollaborationWhenReady(String noteId) {
    if (_disposed ||
        _collaboration != null ||
        _collaborationReadyTimer != null) {
      return;
    }
    _collaborationReadyTimer = Timer(const Duration(seconds: 1), () {
      _collaborationReadyTimer = null;
      unawaited(_ensureCollaboration(noteId));
    });
  }

  Future<void> _startCollaboration(
    String noteId, {
    required String titleBeforeStartup,
    required String contentBeforeStartup,
    required bool preserveTitleBeforeStartup,
    required bool preserveContentBeforeStartup,
  }) async {
    if (_disposed || _collaboration != null) return;
    void Function()? releaseProtection;
    try {
      if (!_remoteShared) {
        releaseProtection = await _repo.protectForCollaboration(noteId);
      }
      final pendingFields = _remoteShared
          ? (
              title: false,
              content: false,
              titleUpdateSeqs: <int>{},
              contentUpdateSeqs: <int>{},
            )
          : await _repo.pendingCollaborativeContent(noteId);
      if (_disposed || _collaboration != null) {
        releaseProtection?.call();
        return;
      }
      _collaborationTitleFallbackSeqs
        ..clear()
        ..addAll(pendingFields.titleUpdateSeqs);
      _collaborationContentFallbackSeqs
        ..clear()
        ..addAll(pendingFields.contentUpdateSeqs);
      final session = CollaborationSession(
        noteId: noteId,
        readTitle: () => _title.text,
        readContent: () => _content.text,
        onSnapshot: _applyCollaborationSnapshot,
        onStateChanged: () {
          if (!mounted || _disposed) return;
          final active = _collaboration;
          if (active?.connection == CollaborationConnection.accessEnded &&
              _remoteShared) {
            _applyingRemote = true;
            _title.clear();
            _content.clear();
            _applyingRemote = false;
            _note = null;
            _loadError =
                active?.lastError ?? 'Your access to this note has ended.';
          }
          setState(() {
            if (active?.connection == CollaborationConnection.live ||
                active?.connection == CollaborationConnection.accessEnded) {
              _collaborationRole = active!.role;
            }
          });
        },
        // User input can arrive while the lease and outbox query above await.
        // Preserve those fields even when their autosave has not run yet.
        preserveInitialTitle:
            pendingFields.title ||
            preserveTitleBeforeStartup ||
            _title.text != titleBeforeStartup,
        preserveInitialContent:
            pendingFields.content ||
            preserveContentBeforeStartup ||
            _content.text != contentBeforeStartup,
        canFlushLocalEdits: () => !_saving && !_dirty,
      );
      _releaseCollaborationProtection = releaseProtection;
      _collaboration = session;
      unawaited(session.connect());
    } catch (_) {
      releaseProtection?.call();
      _scheduleCollaborationWhenReady(noteId);
    }
  }

  void _applyCollaborationSnapshot(CollaborationSnapshot snapshot) {
    if (!mounted || _disposed) return;
    _applyingRemote = true;
    try {
      _replaceControllerText(_title, snapshot.editorTitle);
      _replaceControllerText(_content, snapshot.editorContent);
      _lastTitleText = snapshot.editorTitle;
      _lastContentText = snapshot.editorContent;
      _collaborationRole = snapshot.role;
    } finally {
      _applyingRemote = false;
    }
    final note = _note;
    if (_appliedSnapshotEpoch != snapshot.epoch) {
      _appliedSnapshotEpoch = snapshot.epoch;
      _appliedSnapshotRevision = -1;
    }
    if (note != null && snapshot.revision >= _appliedSnapshotRevision) {
      _appliedSnapshotRevision = snapshot.revision;
      _latestCanonicalTitle = snapshot.title;
      _latestCanonicalContent = snapshot.content;
      if (_remoteShared && snapshot.role == 'owner') {
        final owned = note.copyWith(
          title: snapshot.title,
          content: snapshot.content,
        );
        _note = owned;
        unawaited(
          _repo.cacheSharedNote(owned).then((_) {
            if (_disposed) return;
            _remoteShared = false;
            if (mounted) setState(() {});
          }),
        );
        return;
      }
      if (_remoteShared || snapshot.role != 'owner') {
        _note = note.copyWith(
          title: snapshot.title,
          content: snapshot.content,
          updatedAt: DateTime.now().toUtc(),
        );
        if (mounted) setState(() {});
        return;
      }
      final expectedRevision = snapshot.revision;
      final expectedEpoch = snapshot.epoch;
      final confirmedScopes = <String, Set<int>>{
        if (snapshot.editorTitle == snapshot.title)
          'title': _fallbackSeqsFor('title'),
        if (snapshot.editorContent == snapshot.content)
          'content': _fallbackSeqsFor('content'),
      };
      unawaited(
        _repo
            .applyCollaborativeSnapshot(
              note.id,
              title: snapshot.title,
              content: snapshot.content,
              epoch: snapshot.epoch,
              revision: snapshot.revision,
              acknowledgedUpdateSeqsByField: confirmedScopes,
            )
            .then<void>((updated) {
              for (final entry in confirmedScopes.entries) {
                _removeFallbackSeqs(entry.key, entry.value);
              }
              if (updated == null ||
                  _disposed ||
                  expectedEpoch != _appliedSnapshotEpoch ||
                  expectedRevision < _appliedSnapshotRevision) {
                return;
              }
              _note = updated;
              if (mounted) setState(() {});
            })
            .catchError((_) {}),
      );
    }
  }

  Set<int> _fallbackSeqsFor(String? field) => switch (field) {
    'title' => Set<int>.of(_collaborationTitleFallbackSeqs),
    'content' => Set<int>.of(_collaborationContentFallbackSeqs),
    _ => <int>{},
  };

  void _removeFallbackSeqs(String? field, Set<int> seqs) {
    if (field == 'title') {
      _collaborationTitleFallbackSeqs.removeAll(seqs);
    } else if (field == 'content') {
      _collaborationContentFallbackSeqs.removeAll(seqs);
    }
  }

  Future<void> _refreshCollaborationFallbackScope(
    String noteId, {
    required String desiredTitle,
    required String desiredContent,
  }) async {
    if (_remoteShared || _collaboration == null) return;
    final pending = await _repo.pendingCollaborativeContent(noteId);
    _collaborationTitleFallbackSeqs.addAll(pending.titleUpdateSeqs);
    _collaborationContentFallbackSeqs.addAll(pending.contentUpdateSeqs);
    final epoch = _appliedSnapshotEpoch;
    final canonicalTitle = _latestCanonicalTitle;
    final canonicalContent = _latestCanonicalContent;
    final revision = _appliedSnapshotRevision;
    if (epoch == null ||
        canonicalTitle == null ||
        canonicalContent == null ||
        revision < 0) {
      return;
    }
    final confirmedScopes = <String, Set<int>>{
      if (desiredTitle == canonicalTitle)
        'title': Set<int>.of(_collaborationTitleFallbackSeqs),
      if (desiredContent == canonicalContent)
        'content': Set<int>.of(_collaborationContentFallbackSeqs),
    };
    if (confirmedScopes.values.every((seqs) => seqs.isEmpty)) return;
    await _repo.applyCollaborativeSnapshot(
      noteId,
      title: canonicalTitle,
      content: canonicalContent,
      epoch: epoch,
      revision: revision,
      acknowledgedUpdateSeqsByField: confirmedScopes,
    );
    for (final entry in confirmedScopes.entries) {
      _removeFallbackSeqs(entry.key, entry.value);
    }
  }

  void _replaceControllerText(
    TextEditingController controller,
    String nextText,
  ) {
    final oldText = controller.text;
    if (oldText == nextText) return;
    final selection = controller.selection;
    final moved = transformTextPositions(
      before: oldText,
      after: nextText,
      positions: [selection.baseOffset, selection.extentOffset],
    );

    controller.value = TextEditingValue(
      text: nextText,
      selection: TextSelection(
        baseOffset: moved[0],
        extentOffset: moved[1],
        affinity: selection.affinity,
        isDirectional: selection.isDirectional,
      ),
      composing: TextRange.empty,
    );
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

  Future<void> _drainCollaboration(
    CollaborationSession collaboration, {
    required String? fallbackNoteId,
    Future<void>? waitForSave,
  }) async {
    final releaseProtection = _releaseCollaborationProtection;
    _releaseCollaborationProtection = null;
    try {
      CollaborationCloseResult? result;
      try {
        result = await collaboration.close();
      } catch (_) {
        // Session close normally returns its captured state even if socket
        // teardown fails. Account/app teardown can still make it unavailable.
      }
      if (waitForSave != null) await waitForSave;
      if (result == null || fallbackNoteId == null) return;
      try {
        final confirmedScopes = <String, Set<int>>{
          if (result.canonicalConfirmed &&
              result.title == result.canonicalTitle)
            'title': Set<int>.of(_collaborationTitleFallbackSeqs),
          if (result.canonicalConfirmed &&
              result.content == result.canonicalContent)
            'content': Set<int>.of(_collaborationContentFallbackSeqs),
        };
        // Snapshots are intentionally not published into a disposing widget.
        // Persist the final canonical revision, then retire only field values
        // which fully converged before the socket closed.
        await _repo.applyCollaborativeSnapshot(
          fallbackNoteId,
          title: result.canonicalTitle,
          content: result.canonicalContent,
          epoch: result.epoch,
          revision: result.revision,
          acknowledgedUpdateSeqsByField: confirmedScopes,
        );
        for (final entry in confirmedScopes.entries) {
          _removeFallbackSeqs(entry.key, entry.value);
        }
        if (!result.drained) {
          // Use the session's final rebased desired state. Controller text
          // captured before close can be stale if a remote edit arrives while
          // the drain is in progress. Only enqueue fields that still differ
          // from the last canonical snapshot, so a title-only fallback cannot
          // overwrite newer remote body text (or vice versa).
          final titleChanged = result.title != result.canonicalTitle;
          final contentChanged = result.content != result.canonicalContent;
          if (titleChanged || contentChanged) {
            await _repo.updateNote(
              fallbackNoteId,
              title: titleChanged ? result.title : null,
              content: contentChanged ? result.content : null,
            );
          }
        }
      } catch (_) {
        // App shutdown/account teardown can make the local store unavailable.
      }
    } finally {
      releaseProtection?.call();
    }
  }

  @override
  void dispose() {
    final collaboration = _collaboration;
    final note = _note;
    final fallbackNoteId = _isOwner ? note?.id : null;
    _debounce?.cancel();
    _collaborationReadyTimer?.cancel();
    _collaborationReadyTimer = null;
    final privateEditQueuedBehindSave =
        collaboration == null && _saving && _dirty;
    final capturedTitle = _title.text;
    final capturedContent = _content.text;
    // Flush a pending edit. _save reads the controllers synchronously before
    // its first await, so disposing them right after is safe.
    final saveFuture = _dirty || _saving ? _save() : Future<void>.value();
    _disposed = true;
    if (collaboration != null) {
      unawaited(
        _drainCollaboration(
          collaboration,
          fallbackNoteId: fallbackNoteId,
          waitForSave: saveFuture,
        ),
      );
    } else {
      _releaseCollaborationProtection?.call();
      _releaseCollaborationProtection = null;
      if (privateEditQueuedBehindSave) {
        unawaited(
          saveFuture.then(
            (_) => _persistCapturedDocument(capturedTitle, capturedContent),
          ),
        );
      }
    }
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  void _onTitleChanged() {
    _collaboration?.sendCursor(
      'title',
      _title.selection.baseOffset,
      _title.selection.extentOffset,
    );
    if (_title.text == _lastTitleText) return;
    _lastTitleText = _title.text;
    _onEdited('title');
  }

  void _onContentChanged() {
    _collaboration?.sendCursor(
      'content',
      _content.selection.baseOffset,
      _content.selection.extentOffset,
    );
    if (_content.text == _lastContentText) return;
    _lastContentText = _content.text;
    _onEdited('content');
  }

  void _onEdited(String field) {
    if (_applyingRemote) return;
    final collaboration = _collaboration;
    collaboration?.queueLocalEdit(field);
    // A remotely owned shared note cannot enter this account's local outbox;
    // its session retains and rebases controller text until acknowledgement.
    if (_remoteShared) return;

    // Owner edits always become durable locally before canFlushLocalEdits
    // lets the realtime session transmit them. If the process dies between
    // send and acknowledgement, the scoped outbox row remains recoverable.
    _dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      await _save();
      if (mounted) setState(() {}); // refresh the meta line
    });
  }

  Future<void> _save() async {
    if (_saving) {
      final pending = _saveCompletion;
      if (pending != null) await pending.future;
      // A successful save may have started a second pass for typing which
      // arrived mid-transaction. Explicit actions must wait for that pass too.
      if (_saving) await _save();
      return;
    }
    if (!_dirty) return;
    if (_remoteShared) {
      _dirty = false;
      return;
    }
    _saving = true;
    final completion = Completer<void>();
    _saveCompletion = completion;
    _dirty = false;
    final rawTitle = _title.text;
    final title = normalizeNoteTitle(rawTitle);
    final content = _content.text;
    var persisted = false;
    try {
      final current = _note;
      if (current == null) {
        if (noteDraftIsEmpty(title: rawTitle, content: content)) {
          persisted = true;
          return;
        }
        _note = await _repo.createNote(
          title: title,
          content: content,
          notebookId: widget.initialNotebookId,
        );
        final created = _note;
        if (created != null && !_disposed) {
          unawaited(_ensureCollaboration(created.id));
        }
      } else {
        final savedTitle = title;
        final titleChanged = savedTitle != current.title;
        final contentChanged = content != current.content;
        if (titleChanged || contentChanged) {
          _note = await _repo.updateNote(
            current.id,
            title: titleChanged ? savedTitle : null,
            content: contentChanged ? content : null,
          );
          await _refreshCollaborationFallbackScope(
            current.id,
            desiredTitle: savedTitle,
            desiredContent: content,
          );
        }
      }
      persisted = true;
    } catch (_) {
      // Never send a value which failed to enter the durable outbox. Leave it
      // dirty so another edit, an explicit action, or screen close can retry.
      _dirty = true;
      if (mounted && !_disposed) {
        _toast("Couldn't save this edit locally. It has not been sent yet.");
      }
    } finally {
      _saving = false;
      if (!completion.isCompleted) completion.complete();
      if (identical(_saveCompletion, completion)) {
        _saveCompletion = null;
      }
      // Persist newer typing only after this save succeeded. On failure, keep
      // dirty state without entering a hot retry loop.
      if (persisted && _dirty && !_disposed) {
        unawaited(_save());
      } else if (persisted && !_disposed) {
        _collaboration?.flushNow();
      }
    }
  }

  Future<void> _persistCapturedDocument(
    String capturedTitle,
    String capturedContent,
  ) async {
    try {
      final noteId = _note?.id ?? widget.noteId;
      if (noteId == null) return;
      final latest = await _repo.getNote(noteId);
      if (latest == null) return;
      final title = normalizeNoteTitle(capturedTitle);
      final titleChanged = title != latest.title;
      final contentChanged = capturedContent != latest.content;
      if (titleChanged || contentChanged) {
        await _repo.updateNote(
          noteId,
          title: titleChanged ? title : null,
          content: contentChanged ? capturedContent : null,
        );
      }
    } catch (_) {
      // App/account teardown can make the local store unavailable.
    }
  }

  /// Run [action] with autosave settled first, so it operates on the saved row.
  Future<void> _withSavedNote(Future<void> Function(Note note) action) async {
    _debounce?.cancel();
    await _save();
    if (_dirty) return;
    final note = _note;
    if (note != null) {
      final title = normalizeNoteTitle(_title.text);
      final content = _content.text;
      final hasNewerControllerText =
          title != note.title || content != note.content;
      await action(
        note.copyWith(
          title: title,
          content: content,
          // Online collaboration keeps controller text optimistically ahead of
          // the last acknowledged/persisted snapshot. If an action (notably
          // native export) captures that newer text, its timestamp must describe
          // the same snapshot instead of the older canonical one.
          updatedAt: hasNewerControllerText
              ? DateTime.now().toUtc()
              : note.updatedAt,
        ),
      );
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
    final c = OblixColors.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabHandle(),
            if (_isOwner)
              ListTile(
                leading: Icon(Icons.group_outlined, color: c.inkSecondary),
                title: const Text('Manage access'),
                subtitle: const Text('Add people or change permissions'),
                onTap: () => Navigator.pop(context, 'collaborate'),
              ),
            ListTile(
              leading: Icon(Icons.send_outlined, color: c.inkSecondary),
              title: const Text('Send a copy'),
              subtitle: const Text('Share plain text with another app'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (choice == 'collaborate') {
      await showManageAccessSheet(
        context,
        remote: _collaborationRemote,
        entityType: 'note',
        entityId: note.id,
        name: note.title,
      );
      if (!_disposed) unawaited(_ensureCollaboration(note.id));
      return;
    }
    if (choice != 'copy') return;
    final body = noteShareText(title: note.title, content: note.content);
    await SharePlus.instance.share(ShareParams(text: body));
  });

  Future<void> _exportNote() => _withSavedNote((note) async {
    final c = OblixColors.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetGrabHandle(),
            if (_isOwner)
              ListTile(
                leading: Icon(
                  Icons.archive_outlined,
                  color: c.inkSecondary,
                  size: 20,
                ),
                title: Text(
                  'Oblix note (.oblix)',
                  style: OblixType.ui(c, size: 14.5),
                ),
                onTap: () => Navigator.pop(context, 'oblix'),
              ),
            ListTile(
              leading: Icon(Icons.code, color: c.inkSecondary, size: 20),
              title: Text('Markdown (.md)', style: OblixType.ui(c, size: 14.5)),
              onTap: () => Navigator.pop(context, 'md'),
            ),
            ListTile(
              leading: Icon(
                Icons.description_outlined,
                color: c.inkSecondary,
                size: 20,
              ),
              title: Text(
                'Plain text (.txt)',
                style: OblixType.ui(c, size: 14.5),
              ),
              onTap: () => Navigator.pop(context, 'txt'),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    final List<int>? bytes;
    final String? text;
    final String filename;
    final String mimeType;

    final safeStem = sanitizeSingleExportStem(note.title);

    final io = ImportExportService();

    switch (choice) {
      case 'oblix':
        try {
          bytes = await io.exportNoteOblix(note);
        } on OblixExportException catch (error) {
          _toast(error.toString());
          return;
        }
        text = null;
        filename = '$safeStem.oblix';
        mimeType = 'application/zip';
      case 'md':
        bytes = null;
        text = io.exportNoteMarkdown(note);
        filename = '$safeStem.md';
        mimeType = 'text/markdown';
      case 'txt':
        bytes = null;
        text = io.exportNoteText(note);
        filename = '$safeStem.txt';
        mimeType = 'text/plain';
      default:
        return;
    }

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/$filename';
    if (bytes != null) {
      await File(path).writeAsBytes(bytes, flush: true);
    } else {
      await File(path).writeAsString(text!, flush: true);
    }
    if (!mounted) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: mimeType, name: filename)],
        text: 'Exported note',
      ),
    );
  });

  Future<void> _aiActions() => _withSavedNote((note) async {
    final summary = await showAiActionsSheet(context, note);
    if (summary == null || summary.isEmpty) return;
    // Insert the recap at the top of the body, leaving the original text.
    _content.text = '$summary\n\n${_content.text}';
    _onEdited('content');
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
                leading: Icon(Icons.folder_off_outlined, color: c.inkSecondary),
                title: Text('No notebook', style: OblixType.ui(c, size: 15)),
                selected: note.notebookId == null,
                onTap: () => Navigator.pop(context, [null]),
              ),
              for (final nb in notebooks)
                ListTile(
                  leading: Icon(
                    Icons.menu_book_outlined,
                    color: c.inkSecondary,
                  ),
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
      if (!_disposed) unawaited(_ensureCollaboration(note.id));
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
    final controller = TextEditingController(text: note.tagNames.join(', '));
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
    final names = parseTagNames(result);
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
      if (_collaboration?.connection == CollaborationConnection.live)
        _collaboration!.participants.length <= 1
            ? 'Live'
            : '${_collaboration!.participants.length} live'
      else if (_collaboration?.connection == CollaborationConnection.connecting)
        'Connecting'
      else if (_collaboration?.connection == CollaborationConnection.offline)
        'Offline'
      else if (_collaboration?.connection ==
          CollaborationConnection.accessEnded)
        'Access ended',
    ];
    return parts.join(' · ');
  }

  bool get _isOwner => !_remoteShared && _collaborationRole == 'owner';

  bool get _canEditDocument {
    if (_isOwner) return true;
    return _collaboration?.canEditOnline ?? false;
  }

  String? get _remoteEditingLabel {
    final collaboration = _collaboration;
    if (collaboration == null || collaboration.cursors.isEmpty) return null;
    final activeIds = collaboration.cursors.keys.toSet();
    final names = collaboration.participants
        .where((participant) => activeIds.contains(participant.clientId))
        .map((participant) => participant.displayName)
        .toList();
    if (names.isEmpty) return null;
    if (names.length == 1) return '${names.first} is editing';
    return '${names.take(2).join(' and ')} are editing';
  }

  Widget _unavailableBody(OblixColors c) => SafeArea(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: CircleIconButton(
              Icons.arrow_back_ios_new,
              tooltip: 'Back',
              onTap: () => Navigator.pop(context),
            ),
          ),
        ),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock_outline, size: 38, color: c.inkSecondary),
                  const SizedBox(height: 14),
                  Text(
                    _loadError ?? 'This note is unavailable.',
                    textAlign: TextAlign.center,
                    style: OblixType.ui(c, size: 15, color: c.inkMuted),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton(
                    onPressed: _retryLoad,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final note = _note;
    final pinned = note?.isPinned ?? false;

    return Scaffold(
      backgroundColor: c.surface,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? _unavailableBody(c)
          : SafeArea(
              child: Column(
                children: [
                  // Top bar: back pill (carrying the notebook name) + actions.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        GlassPill(
                          color: c.bg,
                          onTap: () => Navigator.pop(context),
                          padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.arrow_back_ios_new,
                                size: 12,
                                color: c.ink,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _notebookName ?? 'Notes',
                                style: OblixType.ui(
                                  c,
                                  size: 13,
                                  weight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        if (_collaboration?.connection ==
                            CollaborationConnection.live) ...[
                          for (final participant
                              in _collaboration!.participants
                                  .where(
                                    (participant) =>
                                        participant.clientId !=
                                        _collaboration!.clientId,
                                  )
                                  .take(3))
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: OblixAvatar(
                                name: participant.displayName,
                                size: 26,
                              ),
                            ),
                          if (_collaboration!.participants.length > 1)
                            const SizedBox(width: 4),
                        ],
                        if (_isOwner) ...[
                          CircleIconButton(
                            pinned ? Icons.push_pin : Icons.push_pin_outlined,
                            tooltip: pinned ? 'Unpin' : 'Pin',
                            onTap: _togglePin,
                          ),
                          const SizedBox(width: 8),
                        ],
                        CircleIconButton(
                          Icons.ios_share,
                          tooltip: 'Share',
                          onTap: _share,
                        ),
                        const SizedBox(width: 8),
                        if (_isOwner)
                          _OverflowButton(
                            isArchived: note?.isArchived ?? false,
                            onMove: _moveToNotebook,
                            onTags: _editTags,
                            onArchive: _toggleArchive,
                            onDelete: _delete,
                            onExport: _exportNote,
                          )
                        else
                          CircleIconButton(
                            Icons.download_outlined,
                            tooltip: 'Export a copy',
                            onTap: _exportNote,
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
                          readOnly: !_canEditDocument,
                          maxLength: 500,
                          textInputAction: TextInputAction.next,
                          style: OblixType.editorTitle(c),
                          decoration: InputDecoration(
                            hintText: 'Title',
                            hintStyle: OblixType.editorTitle(
                              c,
                            ).copyWith(color: c.inkFaint),
                            border: InputBorder.none,
                            counterText: '',
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(_metaLine, style: OblixType.meta(c)),
                        if (_remoteEditingLabel != null) ...[
                          const SizedBox(height: 5),
                          Text(
                            _remoteEditingLabel!,
                            style: OblixType.ui(
                              c,
                              size: 12,
                              color: c.accentDeep,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ],
                        if (_collaboration?.lastError != null) ...[
                          const SizedBox(height: 5),
                          Text(
                            _collaboration!.lastError!,
                            style: OblixType.ui(c, size: 12, color: c.inkMuted),
                          ),
                        ],
                        if (note != null && note.tagNames.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final tag in note.tagNames)
                                GestureDetector(
                                  onTap: _isOwner ? _editTags : null,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: c.accentSoft,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Text(
                                      '#$tag',
                                      style: OblixType.ui(
                                        c,
                                        size: 12,
                                        weight: FontWeight.w600,
                                        color: c.accentDeep,
                                      ),
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
                          readOnly: !_canEditDocument,
                          maxLines: null,
                          keyboardType: TextInputType.multiline,
                          style: OblixType.noteBody(c),
                          decoration: InputDecoration(
                            hintText: 'Start writing…',
                            hintStyle: OblixType.noteBody(
                              c,
                            ).copyWith(color: c.inkFaint),
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
                        if (_isOwner) ...[
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
                        ] else
                          Text(
                            _collaborationRole == 'viewer'
                                ? 'View only'
                                : _canEditDocument
                                ? 'Can edit'
                                : 'Reconnect to edit',
                            style: OblixType.meta(c),
                          ),
                        const Spacer(),
                        if (_canEditDocument)
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
  final VoidCallback onExport;

  const _OverflowButton({
    required this.isArchived,
    required this.onMove,
    required this.onTags,
    required this.onArchive,
    required this.onDelete,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    return LiquidGlass(
      color: c.bg,
      shape: CircleBorder(side: BorderSide(color: c.hairline)),
      child: PopupMenuButton<String>(
        icon: Icon(Icons.more_horiz, size: 17, color: c.ink),
        tooltip: 'More',
        onSelected: (action) => switch (action) {
          'move' => onMove(),
          'tags' => onTags(),
          'export' => onExport(),
          'archive' => onArchive(),
          'delete' => onDelete(),
          _ => null,
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'move', child: Text('Move to notebook')),
          const PopupMenuItem(value: 'tags', child: Text('Edit tags')),
          const PopupMenuItem(value: 'export', child: Text('Export as…')),
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
