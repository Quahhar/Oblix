import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../core/time/sync_clock.dart';
import '../datasources/local/note_local_datasource.dart';
import '../datasources/local/outbox_dao.dart';
import '../models/note.dart';
import '../models/sync_payload.dart';

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
  })  : _appDb = appDb ?? AppDatabase.instance,
        _local = local ?? NoteLocalDataSource(appDb ?? AppDatabase.instance),
        _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
        _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
        _clock = clock ??
            SyncClock(meta ?? MetaDao(appDb ?? AppDatabase.instance)),
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
  }) {
    return _local.list(
      notebookId: notebookId,
      archived: archived,
      deleted: deleted,
      search: search,
      tagName: tagName,
    );
  }

  Future<Note?> getNote(String noteId) => _local.getById(noteId);

  // --- Writes (local + outbox, one transaction) ---

  Future<Note> createNote({
    String title = 'Untitled',
    String content = '',
    String contentType = 'plain',
    String? notebookId,
    List<String> tagNames = const [],
  }) async {
    final now = await _clock.nowUtc();
    final note = Note(
      id: _uuid.v4(), // client-minted, stable across sync
      userId: await _meta.getUserId() ?? '',
      notebookId: notebookId,
      title: title,
      content: content,
      contentType: contentType,
      createdAt: now,
      updatedAt: now,
      tagNames: tagNames,
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
    final updated = existing.copyWith(
      title: title,
      content: content,
      contentType: contentType,
      notebookId: notebookId ?? existing.notebookId,
      isPinned: isPinned,
      isArchived: isArchived,
      tagNames: tagNames,
      updatedAt: await _clock.nextAfter(existing.updatedAt),
    );
    await _persist(updated, 'update');
    return updated;
  }

  /// Move a note into [notebookId], or out of any notebook when null.
  /// (Separate from [updateNote] because there a null means "unchanged".)
  Future<Note> moveToNotebook(String noteId, String? notebookId) async {
    final existing = await _require(noteId);
    final moved = existing.copyWith(
      notebookId: notebookId,
      updatedAt: await _clock.nextAfter(existing.updatedAt),
    );
    await _persist(moved, 'update');
    return moved;
  }

  Future<void> deleteNote(String noteId) async {
    final existing = await _local.getById(noteId);
    if (existing == null) return;
    final deleted = existing.copyWith(
      isDeleted: true,
      isArchived: false,
      updatedAt: await _clock.nextAfter(existing.updatedAt),
    );
    await _persist(deleted, 'delete');
  }

  Future<Note> restoreNote(String noteId) async {
    final existing = await _require(noteId);
    final restored = existing.copyWith(
      isDeleted: false,
      updatedAt: await _clock.nextAfter(existing.updatedAt),
    );
    await _persist(restored, 'update');
    return restored;
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
        await _local.upsert(txn, note);
        await _outbox.enqueue(
          txn,
          SyncChangeItem(
            entityType: 'note',
            entityId: note.id,
            action: 'create',
            data: note.toJson(),
            deviceId: deviceId,
            timestamp: note.updatedAt.toIso8601String(),
          ),
        );
      }
    });
    _appDb.notifyChanged();
  }

  Future<void> _persist(Note note, String action) async {
    final deviceId = await _meta.getOrCreateDeviceId();
    final change = SyncChangeItem(
      entityType: 'note',
      entityId: note.id,
      action: action,
      data: note.toJson(),
      deviceId: deviceId,
      timestamp: note.updatedAt.toIso8601String(),
    );
    final db = await _appDb.database;
    await db.transaction((txn) async {
      await _local.upsert(txn, note);
      await _outbox.enqueue(txn, change);
    });
    _appDb.notifyChanged();
  }
}
