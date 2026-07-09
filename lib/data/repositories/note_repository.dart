import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
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
  final Uuid _uuid;

  NoteRepository({
    AppDatabase? appDb,
    NoteLocalDataSource? local,
    OutboxDao? outbox,
    MetaDao? meta,
    Uuid? uuid,
  })  : _appDb = appDb ?? AppDatabase.instance,
        _local = local ?? NoteLocalDataSource(appDb ?? AppDatabase.instance),
        _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
        _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
        _uuid = uuid ?? const Uuid();

  /// Fires whenever local note data changes, so callers can re-query.
  Stream<void> get onChanged => _appDb.onChanged;

  // --- Reads (local) ---

  Future<List<Note>> listNotes({
    String? notebookId,
    bool includeArchived = false,
    bool includeDeleted = false,
    String? search,
  }) {
    return _local.list(
      notebookId: notebookId,
      includeArchived: includeArchived,
      includeDeleted: includeDeleted,
      search: search,
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
    final now = DateTime.now().toUtc();
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
    final existing = await _local.getById(noteId);
    if (existing == null) {
      throw StateError('Note $noteId not found locally');
    }
    final updated = existing.copyWith(
      title: title,
      content: content,
      contentType: contentType,
      notebookId: notebookId,
      isPinned: isPinned,
      isArchived: isArchived,
      tagNames: tagNames,
      updatedAt: DateTime.now().toUtc(),
    );
    await _persist(updated, 'update');
    return updated;
  }

  Future<void> deleteNote(String noteId) async {
    final existing = await _local.getById(noteId);
    if (existing == null) return;
    final deleted = existing.copyWith(
      isDeleted: true,
      isArchived: false,
      updatedAt: DateTime.now().toUtc(),
    );
    await _persist(deleted, 'delete');
  }

  Future<Note> restoreNote(String noteId) async {
    final existing = await _local.getById(noteId);
    if (existing == null) {
      throw StateError('Note $noteId not found locally');
    }
    final restored = existing.copyWith(
      isDeleted: false,
      updatedAt: DateTime.now().toUtc(),
    );
    await _persist(restored, 'update');
    return restored;
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
