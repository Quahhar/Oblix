import 'dart:async';

import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../core/time/sync_clock.dart';
import '../datasources/local/note_local_datasource.dart';
import '../datasources/local/outbox_dao.dart';
import '../models/note.dart';
import '../models/sync_payload.dart';
import '../models/crdt_clock.dart';
import '../../core/native/oblix_core.dart';

typedef PendingCollaborativeContent = ({
  bool title,
  bool content,
  Set<int> titleUpdateSeqs,
  Set<int> contentUpdateSeqs,
});

/// Offline-first notes. Every mutation writes the local row AND its outbox entry
/// in a single transaction, then returns immediately — no network on the hot
/// path. Reads always come from local SQLite. The sync engine ships the outbox
/// and merges server changes back in the background.
class NoteRepository {
  final AppDatabase _appDb;
  final NoteLocalDataSource _local;
  final OutboxDao _outbox;
  final MetaDao _meta;
  final SyncClock _clock;
  final Uuid _uuid;

  NoteRepository({
    AppDatabase? appDb,
    NoteLocalDataSource? local,
    OutboxDao? outbox,
    MetaDao? meta,
    SyncClock? clock,
    Uuid? uuid,
  }) : _appDb = appDb ?? AppDatabase.instance,
       _local = local ?? NoteLocalDataSource(appDb ?? AppDatabase.instance),
       _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
       _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
       _clock =
           clock ?? SyncClock(meta ?? MetaDao(appDb ?? AppDatabase.instance)),
       _uuid = uuid ?? const Uuid();

  /// Fires whenever local note data changes, so callers can re-query.
  Stream<void> get onChanged => _appDb.onChanged;

  // --- Reads (local) ---

  /// [archived]/[deleted] are tri-state: false (default) excludes, true
  /// returns only those (Archive/Trash views), null ignores the flag.
  Future<List<Note>> listNotes({
    String? notebookId,
    bool? archived = false,
    bool? deleted = false,
    String? search,
    String? tagName,
  }) async {
    final notes = await _local.list(
      notebookId: notebookId,
      archived: archived,
      deleted: deleted,
      search: search,
      tagName: tagName,
    );
    final userId = await _meta.getUserId();
    if (userId == null) return notes;
    return notes.where((note) => note.userId == userId).toList();
  }

  Future<Note?> getNote(String noteId) async {
    final note = await _local.getById(noteId);
    if (note == null) return null;
    final userId = await _meta.getUserId();
    return userId == null || note.userId == userId ? note : null;
  }

  /// True until this local note has reached the server at least once.
  Future<bool> hasPendingCreate(String noteId) =>
      _outbox.hasPendingCreate('note', noteId);

  /// Which document fields actually have durable local changes waiting to sync.
  ///
  /// Metadata-only outbox entries intentionally return both values as false.
  Future<({bool title, bool content})> pendingCollaborativeContentFields(
    String noteId,
  ) async {
    final pending = await pendingCollaborativeContent(noteId);
    return (title: pending.title, content: pending.content);
  }

  /// Document fields that need preserving plus the exact update rows which
  /// currently make up their durable offline fallback.
  Future<PendingCollaborativeContent> pendingCollaborativeContent(
    String noteId,
  ) async {
    final pending = await _outbox.pendingDataForEntity('note', noteId);
    final fields = pending.fields;
    final preserveAll = fields.contains('*');
    return (
      title: preserveAll || fields.contains('title'),
      content: preserveAll || fields.contains('content'),
      titleUpdateSeqs: pending.updateSeqsFor('title'),
      contentUpdateSeqs: pending.updateSeqsFor('content'),
    );
  }

  /// Prevent background whole-document sync from racing this note's live
  /// operational-transform session. The returned callback is idempotent.
  Future<void Function()> protectForCollaboration(String noteId) async {
    final lease = await _appDb.protectNoteForCollaboration(noteId);
    return lease.release;
  }

  /// Persist an ordered collaboration snapshot without changing the local LWW
  /// timestamp. Advancing `updated_at` here would make the subsequent canonical
  /// server pull look older and could strand stale tags/notebook metadata.
  ///
  /// Calls for a note are serialized, and an older revision in the same epoch
  /// is rejected with `null`, so a slow SQLite write cannot overwrite a newer
  /// snapshot. The session remains responsible for ignoring events from an old
  /// epoch; epochs are opaque UUIDs and cannot be chronologically compared.
  Future<Note?> applyCollaborativeSnapshot(
    String noteId, {
    required String title,
    required String content,
    required String epoch,
    required int revision,
    String? acknowledgedField,
    Set<int> acknowledgedUpdateSeqs = const <int>{},
    Map<String, Set<int>> acknowledgedUpdateSeqsByField =
        const <String, Set<int>>{},
  }) async {
    final retirementScopes = <String, Set<int>>{
      for (final entry in acknowledgedUpdateSeqsByField.entries)
        if ((entry.key == 'title' || entry.key == 'content') &&
            entry.value.isNotEmpty)
          entry.key: Set<int>.of(entry.value),
    };
    if ((acknowledgedField == 'title' || acknowledgedField == 'content') &&
        acknowledgedUpdateSeqs.isNotEmpty) {
      retirementScopes
          .putIfAbsent(acknowledgedField!, () => <int>{})
          .addAll(acknowledgedUpdateSeqs);
    }
    final retiresAcknowledgement = retirementScopes.isNotEmpty;
    final writeTurns = _appDb.collaborativeWriteTurns;
    final revisions = _appDb.collaborativeRevisions;
    final previousTurn = writeTurns[noteId] ?? Future<void>.value();
    final turn = Completer<void>();
    final turnFuture = turn.future;
    writeTurns[noteId] = turnFuture;

    try {
      await previousTurn;
      final last = revisions[noteId];
      final snapshotIsStale = collaborationSnapshotIsStale(
        lastEpoch: last?.epoch,
        lastRevision: last?.revision,
        incomingEpoch: epoch,
        incomingRevision: revision,
      );
      if (snapshotIsStale && !retiresAcknowledgement) {
        return null;
      }

      final db = await _appDb.database;
      Note? updated;
      await db.transaction((txn) async {
        if (snapshotIsStale) {
          final rows = await txn.query(
            'notes',
            columns: const ['id'],
            where: 'id = ?',
            whereArgs: [noteId],
            limit: 1,
          );
          if (rows.isEmpty) {
            throw StateError('Note $noteId not found locally');
          }
        } else {
          updated = await _local.updateFields(txn, noteId, {
            'title': title,
            'content': content,
          });
          if (updated == null) {
            throw StateError('Note $noteId not found locally');
          }
        }
        for (final entry in retirementScopes.entries) {
          await _outbox.retireAcknowledgedUpdateField(
            txn,
            entityType: 'note',
            entityId: noteId,
            field: entry.key,
            scopedSeqs: entry.value,
          );
        }
      });
      if (!snapshotIsStale) {
        revisions[noteId] = (epoch: epoch, revision: revision);
      }
      _appDb.notifyChanged();
      return updated;
    } finally {
      if (!turn.isCompleted) turn.complete();
      if (identical(writeTurns[noteId], turnFuture)) {
        writeTurns.remove(noteId);
      }
    }
  }

  /// Cache a remotely fetched shared note so the normal editor and attachment
  /// UI can render it. No outbox entry is created for another user's entity.
  Future<void> cacheSharedNote(Note note) async {
    final db = await _appDb.database;
    await db.transaction((txn) async {
      final existing = await _local.updateFields(txn, note.id, {
        'title': note.title,
        'content': note.content,
      });
      if (existing == null) {
        await _local.upsert(txn, note);
      }
    });
    _appDb.notifyChanged();
  }

  // --- Writes (local + outbox, one transaction) ---

  Future<Note> createNote({
    String title = 'Untitled',
    String content = '',
    String contentType = 'plain',
    String? notebookId,
    List<String> tagNames = const [],
  }) async {
    final plan = planNoteCreate(
      title: title,
      content: content,
      contentType: contentType,
      notebookId: notebookId,
      tagNames: tagNames,
    );
    final now = await _clock.nowUtc();
    final deviceId = await _meta.getOrCreateDeviceId();
    final note = Note(
      id: _uuid.v4(), // client-minted, stable across sync
      userId: await _meta.getUserId() ?? '',
      notebookId: plan.value.notebookId,
      title: plan.value.title,
      content: plan.value.content,
      contentType: plan.value.contentType,
      isPinned: plan.value.isPinned,
      isArchived: plan.value.isArchived,
      isDeleted: plan.value.isDeleted,
      createdAt: now,
      updatedAt: now,
      tagNames: plan.value.tagNames,
      fieldClocks: stampCrdtFields(
        const {},
        plan.selection.changedFields.toSet(),
        now,
        deviceId,
      ),
    );
    await _persist(note, 'create');
    return note;
  }

  Future<Note> updateNote(
    String noteId, {
    String? title,
    String? content,
    String? contentType,
    String? notebookId,
    bool? isPinned,
    bool? isArchived,
    List<String>? tagNames,
  }) async {
    final existing = await _require(noteId);
    final plan = planNoteUpdate(
      current: _noteMutationState(existing),
      title: title,
      content: content,
      contentType: contentType,
      notebookIdProvided: notebookId != null,
      notebookId: notebookId,
      isPinned: isPinned,
      isArchived: isArchived,
      tagNames: tagNames,
    );
    final changedNames = plan.selection.changedFields.toSet();
    if (changedNames.isEmpty) return existing;
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final clocks = stampCrdtFields(
      existing.fieldClocks,
      changedNames,
      now,
      deviceId,
    );
    final updated = existing.copyWith(
      title: plan.value.title,
      content: plan.value.content,
      contentType: plan.value.contentType,
      notebookId: plan.value.notebookId,
      isPinned: plan.value.isPinned,
      isArchived: plan.value.isArchived,
      isDeleted: plan.value.isDeleted,
      tagNames: plan.value.tagNames,
      updatedAt: now,
      fieldClocks: clocks,
    );
    final changedFields = <String, dynamic>{
      if (title != null) 'title': updated.title,
      if (content != null) 'content': updated.content,
      if (contentType != null) 'content_type': updated.contentType,
      if (notebookId != null) 'notebook_id': updated.notebookId,
      if (isPinned != null) 'is_pinned': updated.isPinned,
      if (isArchived != null) 'is_archived': updated.isArchived,
      if (tagNames != null) 'tags': updated.tagNames,
      'field_clocks': {
        for (final field in changedNames) field: clocks[field]!.toJson(),
      },
    };
    return _persist(
      updated,
      'update',
      data: changedFields,
      localFields: {
        ...changedFields,
        'updated_at': updated.updatedAt,
        'field_clocks': clocks.map(
          (field, clock) => MapEntry(field, clock.toJson()),
        ),
      },
    );
  }

  /// Move a note into [notebookId], or out of any notebook when null.
  /// (Separate from [updateNote] because there a null means "unchanged".)
  Future<Note> moveToNotebook(String noteId, String? notebookId) async {
    final existing = await _require(noteId);
    final plan = planNoteUpdate(
      current: _noteMutationState(existing),
      notebookIdProvided: true,
      notebookId: notebookId,
    );
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final clocks = stampCrdtFields(
      existing.fieldClocks,
      plan.selection.changedFields.toSet(),
      now,
      deviceId,
    );
    final moved = existing.copyWith(
      notebookId: plan.value.notebookId,
      updatedAt: now,
      fieldClocks: clocks,
    );
    return _persist(
      moved,
      'update',
      data: {
        'notebook_id': moved.notebookId,
        'field_clocks': {'notebook_id': clocks['notebook_id']!.toJson()},
      },
      localFields: {
        'notebook_id': moved.notebookId,
        'updated_at': moved.updatedAt,
        'field_clocks': clocks.map(
          (field, clock) => MapEntry(field, clock.toJson()),
        ),
      },
    );
  }

  Future<void> deleteNote(String noteId) async {
    final existing = await _local.getById(noteId);
    if (existing == null) return;
    final plan = planNoteDelete(_noteMutationState(existing));
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final clocks = stampCrdtFields(
      existing.fieldClocks,
      plan.selection.changedFields.toSet(),
      now,
      deviceId,
    );
    final deleted = existing.copyWith(
      isDeleted: plan.value.isDeleted,
      isArchived: plan.value.isArchived,
      updatedAt: now,
      fieldClocks: clocks,
    );
    await _persist(
      deleted,
      'delete',
      localFields: {
        'is_deleted': true,
        'is_archived': false,
        'updated_at': deleted.updatedAt,
        'field_clocks': clocks.map(
          (field, clock) => MapEntry(field, clock.toJson()),
        ),
      },
    );
  }

  Future<Note> restoreNote(String noteId) async {
    final existing = await _require(noteId);
    final plan = planNoteRestore(_noteMutationState(existing));
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final clocks = stampCrdtFields(
      existing.fieldClocks,
      plan.selection.changedFields.toSet(),
      now,
      deviceId,
    );
    final restored = existing.copyWith(
      isDeleted: plan.value.isDeleted,
      updatedAt: now,
      fieldClocks: clocks,
    );
    return _persist(
      restored,
      'update',
      data: {
        'is_deleted': false,
        'field_clocks': {'is_deleted': clocks['is_deleted']!.toJson()},
      },
      localFields: {
        'is_deleted': false,
        'updated_at': restored.updatedAt,
        'field_clocks': clocks.map(
          (field, clock) => MapEntry(field, clock.toJson()),
        ),
      },
    );
  }

  /// Hard-delete every synced tombstone right now (the Trash screen's
  /// "Empty"). Entries still in the outbox are kept so their deletion reaches
  /// the server first; the regular purge drops them later.
  Future<void> emptyTrash() async {
    final db = await _appDb.database;
    await _local.purgeDeletedBefore(db, DateTime.now().toUtc());
    _appDb.notifyChanged();
  }

  Future<Note> _require(String noteId) async {
    final existing = await _local.getById(noteId);
    if (existing == null) {
      throw StateError('Note $noteId not found locally');
    }
    return existing;
  }

  /// Persist a batch of imported notes in one transaction — each with a
  /// `create` outbox entry so the import syncs. Callers mint the ids and
  /// preserve source timestamps. Far cheaper than N separate transactions for
  /// a large import.
  Future<void> importNotes(List<Note> notes) async {
    if (notes.isEmpty) return;
    final deviceId = await _meta.getOrCreateDeviceId();
    final db = await _appDb.database;
    await db.transaction((txn) async {
      for (final note in notes) {
        final stamped = note.copyWith(
          fieldClocks: stampCrdtFields(
            note.fieldClocks,
            Note.crdtFields,
            note.updatedAt,
            deviceId,
          ),
        );
        await _local.upsert(txn, stamped);
        await _outbox.enqueue(
          txn,
          SyncChangeItem(
            entityType: 'note',
            entityId: note.id,
            action: 'create',
            data: stamped.toJson(),
            deviceId: deviceId,
            timestamp: note.updatedAt.toIso8601String(),
          ),
        );
      }
    });
    _appDb.notifyChanged();
  }

  Future<Note> _persist(
    Note note,
    String action, {
    Map<String, dynamic>? data,
    Map<String, Object?>? localFields,
  }) async {
    final deviceId = await _meta.getOrCreateDeviceId();
    final change = SyncChangeItem(
      entityType: 'note',
      entityId: note.id,
      action: action,
      data: data ?? note.toJson(),
      deviceId: deviceId,
      timestamp: note.updatedAt.toIso8601String(),
    );
    final db = await _appDb.database;
    var persisted = note;
    await db.transaction((txn) async {
      if (localFields == null) {
        await _local.upsert(txn, note);
      } else {
        persisted =
            await _local.updateFields(txn, note.id, localFields) ??
            (throw StateError('Note ${note.id} not found locally'));
      }
      await _outbox.enqueue(txn, change);
    });
    _appDb.notifyChanged();
    return persisted;
  }
}

NoteMutationStateValue _noteMutationState(Note note) => (
  title: note.title,
  content: note.content,
  contentType: note.contentType,
  notebookId: note.notebookId,
  isPinned: note.isPinned,
  isArchived: note.isArchived,
  isDeleted: note.isDeleted,
  tagNames: note.tagNames,
);
