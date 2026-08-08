import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../core/time/sync_clock.dart';
import '../datasources/local/outbox_dao.dart';
import '../datasources/local/task_local_datasource.dart';
import '../models/sync_payload.dart';
import '../models/task.dart';

/// Offline-first tasks — same contract as [NoteRepository]: every mutation
/// writes the local row AND its outbox entry in one transaction, reads come
/// from local SQLite, sync reconciles in the background (entity_type 'task').
class TaskRepository {
  final AppDatabase _appDb;
  final TaskLocalDataSource _local;
  final OutboxDao _outbox;
  final MetaDao _meta;
  final SyncClock _clock;
  final Uuid _uuid;

  TaskRepository({
    AppDatabase? appDb,
    TaskLocalDataSource? local,
    OutboxDao? outbox,
    MetaDao? meta,
    SyncClock? clock,
    Uuid? uuid,
  }) : _appDb = appDb ?? AppDatabase.instance,
       _local = local ?? TaskLocalDataSource(appDb ?? AppDatabase.instance),
       _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
       _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
       _clock =
           clock ?? SyncClock(meta ?? MetaDao(appDb ?? AppDatabase.instance)),
       _uuid = uuid ?? const Uuid();

  /// Fires whenever local data changes, so callers can re-query.
  Stream<void> get onChanged => _appDb.onChanged;

  // --- Reads (local) ---

  /// [completed] tri-state: false = open, true = done, null = both.
  Future<List<Task>> listTasks({
    bool? completed = false,
    bool scheduledOnly = false,
    String? noteId,
  }) {
    return _local.list(
      completed: completed,
      scheduledOnly: scheduledOnly,
      noteId: noteId,
    );
  }

  Future<Task?> getTask(String taskId) => _local.getById(taskId);

  Future<int> countOpen() => _local.countOpen();

  // --- Writes (local + outbox, one transaction) ---

  Future<Task> createTask({
    required String title,
    String description = '',
    DateTime? dueDate,
    String? noteId,
  }) async {
    final now = await _clock.nowUtc();
    final deviceId = await _meta.getOrCreateDeviceId();
    final clocks = _stampedClocks(const {}, Task.crdtFields, now, deviceId);
    final task = Task(
      id: _uuid.v4(), // client-minted, stable across sync
      userId: await _meta.getUserId() ?? '',
      noteId: noteId,
      title: title.trim().isEmpty ? 'Untitled task' : title.trim(),
      description: description,
      dueDate: dueDate,
      createdAt: now,
      updatedAt: now,
      fieldClocks: clocks,
    );
    await _persist(task, 'create', Task.crdtFields, deviceId: deviceId);
    return task;
  }

  /// Nullable fields use sentinels internally: pass [clearDueDate] /
  /// [clearNoteId] to detach, since a plain null means "unchanged".
  Future<Task> updateTask(
    String taskId, {
    String? title,
    String? description,
    DateTime? dueDate,
    bool clearDueDate = false,
    String? noteId,
    bool clearNoteId = false,
    int? sortOrder,
  }) async {
    final existing = await _require(taskId);
    final fields = <String>{};
    if (title != null && title != existing.title) fields.add('title');
    if (description != null && description != existing.description) {
      fields.add('description');
    }
    if (clearDueDate || dueDate != null) fields.add('due_date');
    if (clearNoteId || noteId != null) fields.add('note_id');
    if (sortOrder != null && sortOrder != existing.sortOrder) {
      fields.add('sort_order');
    }
    if (fields.isEmpty) return existing;
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final updated = existing.copyWith(
      title: title,
      description: description,
      dueDate: clearDueDate ? null : (dueDate ?? existing.dueDate),
      noteId: clearNoteId ? null : (noteId ?? existing.noteId),
      sortOrder: sortOrder,
      updatedAt: now,
      fieldClocks: _stampedClocks(existing.fieldClocks, fields, now, deviceId),
    );
    await _persist(updated, 'update', fields, deviceId: deviceId);
    return updated;
  }

  /// Check / uncheck. completed_at is stamped locally for instant UI; the
  /// server re-stamps with its own clock on apply.
  Future<Task> setCompleted(String taskId, bool completed) async {
    final existing = await _require(taskId);
    if (existing.isCompleted == completed) return existing;
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final toggled = existing.copyWith(
      isCompleted: completed,
      completedAt: completed ? now : null,
      updatedAt: now,
      fieldClocks: _stampedClocks(
        existing.fieldClocks,
        const {'is_completed'},
        now,
        deviceId,
      ),
    );
    await _persist(toggled, 'update', const {
      'is_completed',
    }, deviceId: deviceId);
    return toggled;
  }

  Future<void> deleteTask(String taskId) async {
    final existing = await _local.getById(taskId);
    if (existing == null) return;
    final now = await _clock.nextAfter(existing.updatedAt);
    final deviceId = await _meta.getOrCreateDeviceId();
    final deleted = existing.copyWith(
      isDeleted: true,
      updatedAt: now,
      fieldClocks: _stampedClocks(
        existing.fieldClocks,
        const {'is_deleted'},
        now,
        deviceId,
      ),
    );
    await _persist(deleted, 'delete', const {'is_deleted'}, deviceId: deviceId);
  }

  Future<Task> _require(String taskId) async {
    final existing = await _local.getById(taskId);
    if (existing == null) {
      throw StateError('Task $taskId not found locally');
    }
    return existing;
  }

  Map<String, TaskCrdtClock> _stampedClocks(
    Map<String, TaskCrdtClock> existing,
    Set<String> fields,
    DateTime timestamp,
    String deviceId,
  ) {
    final clocks = <String, TaskCrdtClock>{...existing};
    for (final field in fields) {
      clocks[field] = TaskCrdtClock(
        timestamp: timestamp.toUtc(),
        deviceId: deviceId,
      );
    }
    return Map.unmodifiable(clocks);
  }

  Future<void> _persist(
    Task task,
    String action,
    Set<String> fields, {
    required String deviceId,
  }) async {
    final data = task.toSyncPatch(fields);
    if (action == 'create') {
      data.addAll({
        'id': task.id,
        'user_id': task.userId,
        'created_at': task.createdAt.toUtc().toIso8601String(),
        'updated_at': task.updatedAt.toUtc().toIso8601String(),
      });
    }
    final change = SyncChangeItem(
      entityType: 'task',
      entityId: task.id,
      action: action,
      data: data,
      deviceId: deviceId,
      timestamp: task.updatedAt.toIso8601String(),
    );
    final db = await _appDb.database;
    await db.transaction((txn) async {
      await _local.upsert(txn, task);
      await _outbox.enqueue(txn, change);
    });
    _appDb.notifyChanged();
  }
}
