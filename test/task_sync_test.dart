// Task layer tests: offline-first writes (row + outbox in one transaction),
// list filters/ordering for the Tasks screen, LWW merge of server tasks, and
// end-to-end apply of server 'task' changes through the sync engine.

import 'package:oblix/core/db/app_database.dart';
import 'package:oblix/core/db/meta_dao.dart';
import 'package:oblix/data/datasources/local/attachment_local_datasource.dart';
import 'package:oblix/data/datasources/local/note_local_datasource.dart';
import 'package:oblix/data/datasources/local/notebook_local_datasource.dart';
import 'package:oblix/data/datasources/local/outbox_dao.dart';
import 'package:oblix/data/datasources/local/tag_local_datasource.dart';
import 'package:oblix/data/datasources/local/task_local_datasource.dart';
import 'package:oblix/data/datasources/remote/sync_remote_datasource.dart';
import 'package:oblix/data/models/sync_payload.dart';
import 'package:oblix/data/repositories/task_repository.dart';
import 'package:oblix/domain/usecases/sync_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeRemote extends SyncRemoteDataSource {
  _FakeRemote(List<SyncPushResponse> responses) : _script = [...responses];

  final List<SyncPushResponse> _script;
  final List<List<SyncChangeItem>> pushes = [];

  @override
  Future<SyncPushResponse> pushChanges({
    required List<SyncChangeItem> changes,
    String? lastSyncAt,
  }) async {
    pushes.add(changes);
    return _script.length > 1 ? _script.removeAt(0) : _script.first;
  }
}

Map<String, dynamic> _taskChange(
  String id, {
  required String title,
  required DateTime editedAt,
  bool isCompleted = false,
  bool isDeleted = false,
  String? dueDate,
  Map<String, dynamic>? fieldClocks,
}) {
  final iso = editedAt.toUtc().toIso8601String();
  return {
    'entity_type': 'task',
    'entity_id': id,
    'action': isDeleted ? 'delete' : 'update',
    'data': {
      'id': id,
      'user_id': 'u1',
      'note_id': null,
      'title': title,
      'description': '',
      'is_completed': isCompleted,
      'completed_at': null,
      'due_date': dueDate,
      'sort_order': 0,
      'is_deleted': isDeleted,
      'created_at': iso,
      // Server emits both; the client must merge on edited_at.
      'updated_at': '2030-01-01T00:00:00.000Z',
      'edited_at': iso,
      'field_clocks': fieldClocks ?? <String, dynamic>{},
    },
  };
}

SyncPushResponse _resp({
  List<String> applied = const [],
  List<Map<String, dynamic>> serverChanges = const [],
  String serverTime = '2026-07-09T12:00:00.000Z',
}) => SyncPushResponse(
  applied: applied,
  conflicts: const [],
  serverChanges: serverChanges,
  serverTime: serverTime,
);

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late TaskLocalDataSource tasks;
  late OutboxDao outbox;
  late MetaDao meta;
  late TaskRepository repo;

  setUp(() async {
    db = AppDatabase.ephemeral(
      dbFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    tasks = TaskLocalDataSource(db);
    outbox = OutboxDao(db);
    meta = MetaDao(db);
    repo = TaskRepository(appDb: db, local: tasks, outbox: outbox, meta: meta);
    await meta.setUserId('u1');
  });

  tearDown(() async {
    await db.close();
  });

  SyncEngine engine(SyncRemoteDataSource remote) => SyncEngine(
    appDb: db,
    remote: remote,
    outbox: outbox,
    notes: NoteLocalDataSource(db),
    notebooks: NotebookLocalDataSource(db),
    tags: TagLocalDataSource(db),
    tasks: tasks,
    attachments: AttachmentLocalDataSource(db),
    meta: meta,
  );

  group('local task writes', () {
    test('create writes row and enqueues a task outbox entry', () async {
      final task = await repo.createTask(title: 'Buy milk');

      expect(await outbox.pendingCount(), 1);
      final entry = (await outbox.fetchBatch()).single.change;
      expect(entry.entityType, 'task');
      expect(entry.action, 'create');
      expect(entry.data['title'], 'Buy milk');

      expect((await tasks.getById(task.id))!.title, 'Buy milk');
    });

    test('setCompleted stamps completed_at and clears it on uncheck', () async {
      final task = await repo.createTask(title: 'T');

      final done = await repo.setCompleted(task.id, true);
      expect(done.isCompleted, isTrue);
      expect(done.completedAt, isNotNull);
      expect(done.updatedAt.isAfter(task.updatedAt), isTrue);

      final reopened = await repo.setCompleted(task.id, false);
      expect(reopened.isCompleted, isFalse);
      expect(reopened.completedAt, isNull);

      // no-op toggle does not enqueue another change
      final before = await outbox.pendingCount();
      await repo.setCompleted(task.id, false);
      expect(await outbox.pendingCount(), before);
    });

    test('completion queues only the completion CRDT register', () async {
      final task = await repo.createTask(title: 'Keep this title');
      await repo.setCompleted(task.id, true);

      final entries = await outbox.fetchBatch();
      final completion = entries.last.change.data;
      expect(completion['is_completed'], isTrue);
      expect(completion['completed_at'], isNotNull);
      expect(completion.containsKey('title'), isFalse);
      expect(
        (completion['field_clocks'] as Map).keys,
        contains('is_completed'),
      );
    });

    test('updateTask can clear a due date via clearDueDate', () async {
      final task = await repo.createTask(
        title: 'T',
        dueDate: DateTime.utc(2026, 8, 1),
      );
      expect((await tasks.getById(task.id))!.dueDate, isNotNull);

      await repo.updateTask(task.id, clearDueDate: true);
      expect((await tasks.getById(task.id))!.dueDate, isNull);
    });

    test('list filters by state and orders dated-first', () async {
      final overdue = await repo.createTask(
        title: 'overdue',
        dueDate: DateTime.utc(2026, 1, 1),
      );
      final later = await repo.createTask(
        title: 'later',
        dueDate: DateTime.utc(2026, 12, 1),
      );
      final undated = await repo.createTask(title: 'someday');
      final done = await repo.createTask(title: 'done');
      await repo.setCompleted(done.id, true);

      final open = await repo.listTasks();
      expect(open.map((t) => t.id), [overdue.id, later.id, undated.id]);

      final scheduled = await repo.listTasks(scheduledOnly: true);
      expect(scheduled.map((t) => t.id), [overdue.id, later.id]);

      final completed = await repo.listTasks(completed: true);
      expect(completed.single.id, done.id);

      expect(await repo.countOpen(), 3);
    });

    test('deleteTask tombstones and hides from lists', () async {
      final task = await repo.createTask(title: 'doomed');
      await repo.deleteTask(task.id);

      expect(await repo.listTasks(completed: null), isEmpty);
      expect((await tasks.getById(task.id))!.isDeleted, isTrue);
      final actions = (await outbox.fetchBatch())
          .map((e) => e.change.action)
          .toList();
      expect(actions, ['create', 'delete']);
    });
  });

  group('sync', () {
    test(
      'engine applies server task changes and merges on edited_at',
      () async {
        final remote = _FakeRemote([
          _resp(
            serverChanges: [
              _taskChange(
                'srv-task',
                title: 'from server',
                editedAt: DateTime.now(),
              ),
            ],
          ),
        ]);

        final result = await engine(remote).syncOnce();

        expect(result.success, isTrue);
        expect(result.pulled, 1);
        final stored = await tasks.getById('srv-task');
        expect(stored!.title, 'from server');
        // edited_at (not the far-future updated_at) became the LWW basis.
        expect(stored.updatedAt.year, DateTime.now().toUtc().year);
      },
    );

    test('LWW keeps a newer local task over an older server version', () async {
      final local = await repo.createTask(title: 'newer local');

      final remote = _FakeRemote([
        _resp(
          applied: [local.id],
          serverChanges: [
            _taskChange(
              local.id,
              title: 'older server',
              editedAt: local.updatedAt.subtract(const Duration(days: 1)),
            ),
          ],
        ),
      ]);

      await engine(remote).syncOnce();

      expect((await tasks.getById(local.id))!.title, 'newer local');
    });

    test('server task tombstone hides the task locally', () async {
      final local = await repo.createTask(title: 'kill me elsewhere');
      final remote = _FakeRemote([
        _resp(
          applied: [local.id],
          serverChanges: [
            _taskChange(
              local.id,
              title: 'kill me elsewhere',
              editedAt: local.updatedAt.add(const Duration(seconds: 1)),
              isDeleted: true,
            ),
          ],
        ),
      ]);

      await engine(remote).syncOnce();

      expect(await repo.listTasks(completed: null), isEmpty);
      expect((await tasks.getById(local.id))!.isDeleted, isTrue);
    });

    test('concurrent server title and local completion both survive', () async {
      final created = await repo.createTask(title: 'Original');
      final completed = await repo.setCompleted(created.id, true);
      final serverTitleTime = completed.updatedAt.add(
        const Duration(seconds: 1),
      );
      final oldCompletionTime = created.updatedAt;
      final remote = _FakeRemote([
        _resp(
          applied: [created.id],
          serverChanges: [
            _taskChange(
              created.id,
              title: 'Automated title',
              editedAt: serverTitleTime,
              fieldClocks: {
                'title': {
                  'timestamp': serverTitleTime.toIso8601String(),
                  'device_id': 'laptop',
                },
                'is_completed': {
                  'timestamp': oldCompletionTime.toIso8601String(),
                  'device_id': 'laptop',
                },
              },
            ),
          ],
        ),
      ]);

      await engine(remote).syncOnce();

      final merged = await tasks.getById(created.id);
      expect(merged!.title, 'Automated title');
      expect(merged.isCompleted, isTrue);
    });
  });
}
