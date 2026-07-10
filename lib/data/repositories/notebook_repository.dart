import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../core/time/sync_clock.dart';
import '../datasources/local/notebook_local_datasource.dart';
import '../datasources/local/outbox_dao.dart';
import '../models/notebook.dart';
import '../models/sync_payload.dart';

/// Offline-first notebooks. Same contract as [NoteRepository]: every mutation
/// writes the local row and its outbox entry in one transaction and returns
/// immediately; reads come from local SQLite.
class NotebookRepository {
  final AppDatabase _appDb;
  final NotebookLocalDataSource _local;
  final OutboxDao _outbox;
  final MetaDao _meta;
  final SyncClock _clock;
  final Uuid _uuid;

  NotebookRepository({
    AppDatabase? appDb,
    NotebookLocalDataSource? local,
    OutboxDao? outbox,
    MetaDao? meta,
    SyncClock? clock,
    Uuid? uuid,
  })  : _appDb = appDb ?? AppDatabase.instance,
        _local =
            local ?? NotebookLocalDataSource(appDb ?? AppDatabase.instance),
        _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
        _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
        _clock = clock ??
            SyncClock(meta ?? MetaDao(appDb ?? AppDatabase.instance)),
        _uuid = uuid ?? const Uuid();

  Stream<void> get onChanged => _appDb.onChanged;

  // --- Reads (local) ---

  Future<List<Notebook>> listNotebooks({bool includeDeleted = false}) =>
      _local.list(includeDeleted: includeDeleted);

  Future<Notebook?> getNotebook(String id) => _local.getById(id);

  // --- Writes (local + outbox, one transaction) ---

  Future<Notebook> createNotebook({
    required String name,
    String? parentId,
    int sortOrder = 0,
  }) async {
    final now = await _clock.nowUtc();
    final notebook = Notebook(
      id: _uuid.v4(),
      userId: await _meta.getUserId() ?? '',
      name: name,
      parentId: parentId,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
    );
    await _persist(notebook, 'create');
    return notebook;
  }

  Future<Notebook> updateNotebook(
    String id, {
    String? name,
    String? parentId,
    int? sortOrder,
  }) async {
    final existing = await _require(id);
    final updated = existing.copyWith(
      name: name,
      parentId: parentId ?? existing.parentId,
      sortOrder: sortOrder,
      updatedAt: await _clock.nextAfter(existing.updatedAt),
    );
    await _persist(updated, 'update');
    return updated;
  }

  /// Re-parent a notebook; null moves it to the top level. (Separate from
  /// [updateNotebook] because there a null means "unchanged".)
  Future<Notebook> moveNotebook(String id, String? parentId) async {
    final existing = await _require(id);
    final moved = existing.copyWith(
      parentId: parentId,
      updatedAt: await _clock.nextAfter(existing.updatedAt),
    );
    await _persist(moved, 'update');
    return moved;
  }

  Future<void> deleteNotebook(String id) async {
    final existing = await _local.getById(id);
    if (existing == null) return;
    final deleted = existing.copyWith(
      isDeleted: true,
      updatedAt: await _clock.nextAfter(existing.updatedAt),
    );
    await _persist(deleted, 'delete');
  }

  Future<Notebook> _require(String id) async {
    final existing = await _local.getById(id);
    if (existing == null) {
      throw StateError('Notebook $id not found locally');
    }
    return existing;
  }

  Future<void> _persist(Notebook notebook, String action) async {
    final deviceId = await _meta.getOrCreateDeviceId();
    final change = SyncChangeItem(
      entityType: 'notebook',
      entityId: notebook.id,
      action: action,
      data: notebook.toJson(),
      deviceId: deviceId,
      timestamp: notebook.updatedAt.toIso8601String(),
    );
    final db = await _appDb.database;
    await db.transaction((txn) async {
      await _local.upsert(txn, notebook);
      await _outbox.enqueue(txn, change);
    });
    _appDb.notifyChanged();
  }
}
