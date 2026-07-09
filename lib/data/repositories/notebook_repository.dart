import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
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
  final Uuid _uuid;

  NotebookRepository({
    AppDatabase? appDb,
    NotebookLocalDataSource? local,
    OutboxDao? outbox,
    MetaDao? meta,
    Uuid? uuid,
  })  : _appDb = appDb ?? AppDatabase.instance,
        _local =
            local ?? NotebookLocalDataSource(appDb ?? AppDatabase.instance),
        _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
        _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
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
    final now = DateTime.now().toUtc();
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
    final existing = await _local.getById(id);
    if (existing == null) {
      throw StateError('Notebook $id not found locally');
    }
    final updated = existing.copyWith(
      name: name,
      parentId: parentId,
      sortOrder: sortOrder,
      updatedAt: DateTime.now().toUtc(),
    );
    await _persist(updated, 'update');
    return updated;
  }

  Future<void> deleteNotebook(String id) async {
    final existing = await _local.getById(id);
    if (existing == null) return;
    final deleted = existing.copyWith(
      isDeleted: true,
      updatedAt: DateTime.now().toUtc(),
    );
    await _persist(deleted, 'delete');
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
