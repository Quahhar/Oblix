import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../core/native/oblix_core.dart';
import '../../core/time/sync_clock.dart';
import '../datasources/local/notebook_local_datasource.dart';
import '../datasources/local/outbox_dao.dart';
import '../models/notebook.dart';
import '../models/sync_payload.dart';
import '../models/crdt_clock.dart';

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
  }) : _appDb = appDb ?? AppDatabase.instance,
       _local = local ?? NotebookLocalDataSource(appDb ?? AppDatabase.instance),
       _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
       _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
       _clock =
           clock ?? SyncClock(meta ?? MetaDao(appDb ?? AppDatabase.instance)),
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
    final plan = planNotebookCreate(
      name: name,
      parentId: parentId,
      sortOrder: sortOrder,
    );
    final now = await _clock.nowUtc();
    final deviceId = await _meta.getOrCreateDeviceId();
    final notebook = Notebook(
      id: _uuid.v4(),
      userId: await _meta.getUserId() ?? '',
      name: plan.value.name,
      parentId: plan.value.parentId,
      sortOrder: plan.value.sortOrder,
      isDeleted: plan.value.isDeleted,
      createdAt: now,
      updatedAt: now,
      fieldClocks: stampCrdtFields(
        const {},
        plan.selection.changedFields.toSet(),
        now,
        deviceId,
      ),
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
    final plan = planNotebookUpdate(
      current: _notebookMutationState(existing),
      name: name,
      parentIdProvided: parentId != null,
      parentId: parentId,
      sortOrder: sortOrder,
    );
    final fields = plan.selection.changedFields.toSet();
    if (fields.isEmpty) return existing;
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final clocks = stampCrdtFields(existing.fieldClocks, fields, now, deviceId);
    final updated = existing.copyWith(
      name: plan.value.name,
      parentId: plan.value.parentId,
      sortOrder: plan.value.sortOrder,
      isDeleted: plan.value.isDeleted,
      updatedAt: now,
      fieldClocks: clocks,
    );
    await _persist(updated, 'update', data: _patch(updated, fields));
    return updated;
  }

  /// Re-parent a notebook; null moves it to the top level. (Separate from
  /// [updateNotebook] because there a null means "unchanged".)
  Future<Notebook> moveNotebook(String id, String? parentId) async {
    final existing = await _require(id);
    final plan = planNotebookUpdate(
      current: _notebookMutationState(existing),
      parentIdProvided: true,
      parentId: parentId,
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
      parentId: plan.value.parentId,
      updatedAt: now,
      fieldClocks: clocks,
    );
    await _persist(
      moved,
      'update',
      data: _patch(moved, plan.selection.changedFields.toSet()),
    );
    return moved;
  }

  Future<void> deleteNotebook(String id) async {
    final existing = await _local.getById(id);
    if (existing == null) return;
    final plan = planNotebookDelete(_notebookMutationState(existing));
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
      updatedAt: now,
      fieldClocks: clocks,
    );
    await _persist(
      deleted,
      'delete',
      data: _patch(deleted, plan.selection.changedFields.toSet()),
    );
  }

  Future<Notebook> _require(String id) async {
    final existing = await _local.getById(id);
    if (existing == null) {
      throw StateError('Notebook $id not found locally');
    }
    return existing;
  }

  Map<String, dynamic> _patch(Notebook notebook, Set<String> fields) => {
    if (fields.contains('name')) 'name': notebook.name,
    if (fields.contains('parent_id')) 'parent_id': notebook.parentId,
    if (fields.contains('sort_order')) 'sort_order': notebook.sortOrder,
    if (fields.contains('is_deleted')) 'is_deleted': notebook.isDeleted,
    'field_clocks': {
      for (final field in fields) field: notebook.fieldClocks[field]!.toJson(),
    },
  };

  Future<void> _persist(
    Notebook notebook,
    String action, {
    Map<String, dynamic>? data,
  }) async {
    final deviceId = await _meta.getOrCreateDeviceId();
    final change = SyncChangeItem(
      entityType: 'notebook',
      entityId: notebook.id,
      action: action,
      data: data ?? notebook.toJson(),
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

NotebookMutationStateValue _notebookMutationState(Notebook notebook) => (
  name: notebook.name,
  parentId: notebook.parentId,
  sortOrder: notebook.sortOrder,
  isDeleted: notebook.isDeleted,
);
