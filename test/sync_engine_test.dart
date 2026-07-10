// End-to-end tests for the offline-first sync engine, run against a real (but
// in-memory) SQLite database via sqflite_common_ffi — no device or network.
//
// These exercise the contract that matters for correctness:
//   * local writes land in the DB and the outbox (including tags),
//   * a sync cycle pushes the outbox, merges server changes, advances the
//     cursor, and settles exactly what the server acknowledged,
//   * large backlogs drain fully within one cycle,
//   * unacknowledged entries retry a bounded number of times, then drop,
//   * last-write-wins protects a newer local edit from an older server version,
//   * synced tombstones are purged after the retention window,
//   * FTS search (including the INSERT OR REPLACE update path) works.

import 'package:cyclux/core/db/app_database.dart';
import 'package:cyclux/core/db/meta_dao.dart';
import 'package:cyclux/core/network/api_exceptions.dart';
import 'package:cyclux/data/datasources/local/note_local_datasource.dart';
import 'package:cyclux/data/datasources/local/notebook_local_datasource.dart';
import 'package:cyclux/data/datasources/local/outbox_dao.dart';
import 'package:cyclux/data/datasources/local/tag_local_datasource.dart';
import 'package:cyclux/data/datasources/remote/sync_remote_datasource.dart';
import 'package:cyclux/data/models/sync_payload.dart';
import 'package:cyclux/data/models/tag.dart';
import 'package:cyclux/data/repositories/note_repository.dart';
import 'package:cyclux/domain/usecases/sync_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fake transport: records every push and returns scripted responses
/// (the last response repeats once the script runs out).
class _FakeRemote extends SyncRemoteDataSource {
  _FakeRemote(List<SyncPushResponse> responses) : _script = [...responses];

  final List<SyncPushResponse> _script;
  final List<List<SyncChangeItem>> pushes = [];
  final List<String?> cursors = [];

  @override
  Future<SyncPushResponse> pushChanges({
    required List<SyncChangeItem> changes,
    String? lastSyncAt,
  }) async {
    pushes.add(changes);
    cursors.add(lastSyncAt);
    return _script.length > 1 ? _script.removeAt(0) : _script.first;
  }
}

class _ThrowingRemote extends SyncRemoteDataSource {
  _ThrowingRemote([this.error]);
  final Object? error;

  @override
  Future<SyncPushResponse> pushChanges({
    required List<SyncChangeItem> changes,
    String? lastSyncAt,
  }) async {
    throw error ?? Exception('network down');
  }
}

Map<String, dynamic> _noteChange(
  String id, {
  required String title,
  required DateTime updatedAt,
  List<dynamic> tags = const [],
}) {
  final iso = updatedAt.toUtc().toIso8601String();
  return {
    'entity_type': 'note',
    'entity_id': id,
    'action': 'update',
    'data': {
      'id': id,
      'user_id': 'u1',
      'title': title,
      'content': '',
      'content_type': 'plain',
      'is_pinned': false,
      'is_archived': false,
      'is_deleted': false,
      'created_at': iso,
      'updated_at': iso,
      'tags': tags,
    },
  };
}

Map<String, dynamic> _notebookChange(String id, String name, DateTime at) {
  final iso = at.toUtc().toIso8601String();
  return {
    'entity_type': 'notebook',
    'entity_id': id,
    'action': 'update',
    'data': {
      'id': id,
      'user_id': 'u1',
      'name': name,
      'parent_id': null,
      'sort_order': 0,
      'is_deleted': false,
      'created_at': iso,
      'updated_at': iso,
    },
  };
}

Map<String, dynamic> _tagChange(
  String id,
  String name,
  DateTime at, {
  bool isDeleted = false,
}) {
  final iso = at.toUtc().toIso8601String();
  return {
    'entity_type': 'tag',
    'entity_id': id,
    'action': isDeleted ? 'delete' : 'update',
    'data': {
      'id': id,
      'user_id': 'u1',
      'name': name,
      'is_deleted': isDeleted,
      'created_at': iso,
      'updated_at': iso,
    },
  };
}

SyncPushResponse _resp({
  List<String> applied = const [],
  List<Map<String, dynamic>> serverChanges = const [],
  String serverTime = '',
}) =>
    SyncPushResponse(
      applied: applied,
      conflicts: const [],
      serverChanges: serverChanges,
      serverTime: serverTime,
    );

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late NoteLocalDataSource notes;
  late NotebookLocalDataSource notebooks;
  late TagLocalDataSource tags;
  late OutboxDao outbox;
  late MetaDao meta;
  late NoteRepository noteRepo;

  setUp(() async {
    // A fresh in-memory database per test.
    db = AppDatabase.ephemeral(
      dbFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    notes = NoteLocalDataSource(db);
    notebooks = NotebookLocalDataSource(db);
    tags = TagLocalDataSource(db);
    outbox = OutboxDao(db);
    meta = MetaDao(db);
    noteRepo = NoteRepository(
      appDb: db,
      local: notes,
      outbox: outbox,
      meta: meta,
    );
    await meta.setUserId('u1');
  });

  tearDown(() async {
    await db.close();
  });

  SyncEngine engineWith(
    SyncRemoteDataSource remote, {
    int batchSize = 100,
    int maxPushAttempts = 5,
  }) =>
      SyncEngine(
        appDb: db,
        remote: remote,
        outbox: outbox,
        notes: notes,
        notebooks: notebooks,
        tags: tags,
        meta: meta,
        batchSize: batchSize,
        maxPushAttempts: maxPushAttempts,
      );

  group('local writes', () {
    test('create writes note and enqueues one outbox entry', () async {
      final note = await noteRepo.createNote(title: 'A');

      expect(await outbox.pendingCount(), 1);
      final stored = await notes.getById(note.id);
      expect(stored, isNotNull);
      expect(stored!.title, 'A');
    });

    test('outbox change data carries tags', () async {
      await noteRepo.createNote(title: 'A', tagNames: ['work', 'ideas']);

      final batch = await outbox.fetchBatch();
      expect(batch.single.change.data['tags'], ['work', 'ideas']);
    });

    test('moveToNotebook(null) clears the notebook', () async {
      final note =
          await noteRepo.createNote(title: 'A', notebookId: 'nb-1');
      await noteRepo.moveToNotebook(note.id, null);

      final stored = await notes.getById(note.id);
      expect(stored!.notebookId, isNull);
    });

    test('edits are monotonically timestamped', () async {
      final note = await noteRepo.createNote(title: 'A');
      final updated = await noteRepo.updateNote(note.id, title: 'B');
      expect(updated.updatedAt.isAfter(note.updatedAt), isTrue);
    });
  });

  group('sync cycle', () {
    test('pushes outbox, merges server entities, advances cursor, drains',
        () async {
      final local = await noteRepo.createNote(title: 'local');

      final remote = _FakeRemote([
        _resp(
          serverChanges: [
            _noteChange('srv-note',
                title: 'from server', updatedAt: DateTime.now()),
            _notebookChange('srv-nb', 'Inbox', DateTime.now()),
            _tagChange('srv-tag', 'work', DateTime.now()),
          ],
          serverTime: '2026-07-09T12:00:00.000Z',
        ),
      ]);

      final result = await engineWith(remote).syncOnce();

      expect(result.success, isTrue);
      expect(result.pushed, 1);
      expect(result.pulled, 3); // note + notebook + tag

      // The local note was the thing pushed.
      expect(remote.pushes.single.single.entityId, local.id);
      expect(remote.cursors.single, isNull); // first sync has no prior cursor

      // Outbox drained, cursor advanced, clock skew recorded.
      expect(await outbox.pendingCount(), 0);
      expect(await meta.getCursor(), '2026-07-09T12:00:00.000Z');
      expect(await meta.getClockSkew(), isNot(Duration.zero));

      // Server entities merged into their local mirrors.
      expect(await notes.getById('srv-note'), isNotNull);
      expect((await notebooks.getById('srv-nb'))!.name, 'Inbox');
      expect((await tags.getById('srv-tag'))!.name, 'work');
    });

    test('server echo with equal timestamp keeps tags (regression)', () async {
      final local =
          await noteRepo.createNote(title: 'tagged', tagNames: ['work']);

      // The server echoes our own note back with the SAME timestamp, tags in
      // the server's [{"name": ...}] shape.
      final remote = _FakeRemote([
        _resp(
          applied: [local.id],
          serverChanges: [
            _noteChange(
              local.id,
              title: 'tagged',
              updatedAt: local.updatedAt,
              tags: [
                {'name': 'work'},
              ],
            ),
          ],
          serverTime: '2026-07-09T12:00:00.000Z',
        ),
      ]);

      await engineWith(remote).syncOnce();

      final merged = await notes.getById(local.id);
      expect(merged!.tagNames, ['work']);
    });

    test('drains a large backlog in one cycle', () async {
      await noteRepo.createNote(title: 'one');
      await noteRepo.createNote(title: 'two');
      await noteRepo.createNote(title: 'three');

      final remote = _FakeRemote([_resp()]);
      final result =
          await engineWith(remote, batchSize: 2).syncOnce();

      expect(result.pushed, 3);
      expect(remote.pushes, hasLength(2)); // 2 + 1
      expect(remote.pushes.first, hasLength(2));
      expect(remote.pushes.last, hasLength(1));
      expect(await outbox.pendingCount(), 0);
    });

    test('unacked entries retry with bounded attempts, then drop', () async {
      final acked = await noteRepo.createNote(title: 'good');
      final ignored = await noteRepo.createNote(title: 'poison');

      // Server acknowledges only the first note, never mentions the second.
      final remote = _FakeRemote([
        _resp(applied: [acked.id], serverTime: '2026-07-09T12:00:00.000Z'),
      ]);
      final engine = engineWith(remote, maxPushAttempts: 2);

      final first = await engine.syncOnce();
      expect(first.pushed, 1);
      expect(first.rejected, 0);
      expect(await outbox.pendingCount(), 1); // poison entry retained

      final second = await engine.syncOnce();
      expect(second.rejected, 1); // attempts exhausted → dropped
      expect(await outbox.pendingCount(), 0);

      // The local row itself is untouched — only its push was abandoned.
      expect(await notes.getById(ignored.id), isNotNull);
    });

    test('last-write-wins keeps a newer local note over an older server version',
        () async {
      final local = await noteRepo.createNote(title: 'newer local');

      // Server reports the same note but a full day older.
      final stale = _noteChange(
        local.id,
        title: 'older server',
        updatedAt: local.updatedAt.subtract(const Duration(days: 1)),
      );
      final remote = _FakeRemote([
        _resp(
          applied: [local.id],
          serverChanges: [stale],
          serverTime: '2026-07-09T12:00:00.000Z',
        ),
      ]);

      await engineWith(remote).syncOnce();

      final merged = await notes.getById(local.id);
      expect(merged!.title, 'newer local'); // local edit preserved
    });

    test('transport failure leaves outbox and cursor untouched', () async {
      await noteRepo.createNote(title: 'A');

      final result = await engineWith(_ThrowingRemote()).syncOnce();

      expect(result.success, isFalse);
      expect(result.unauthorized, isFalse);
      expect(await outbox.pendingCount(), 1); // still queued for retry
      expect(await meta.getCursor(), isNull); // cursor not advanced
    });

    test('401 is reported as unauthorized', () async {
      final result = await engineWith(
        _ThrowingRemote(UnauthorizedException()),
      ).syncOnce();

      expect(result.success, isFalse);
      expect(result.unauthorized, isTrue);
    });

    test('server tag tombstone hides the tag locally', () async {
      final now = DateTime.now();
      final remote = _FakeRemote([
        _resp(
          serverChanges: [_tagChange('t1', 'obsolete', now, isDeleted: true)],
          serverTime: '2026-07-09T12:00:00.000Z',
        ),
      ]);

      await engineWith(remote).syncOnce();

      expect(await tags.list(), isEmpty);
      expect((await tags.getById('t1'))!.isDeleted, isTrue);
    });

    test('synced tombstones older than retention are purged', () async {
      final note = await noteRepo.createNote(title: 'doomed');
      await noteRepo.deleteNote(note.id);

      final remote = _FakeRemote([_resp()]); // ack-all (legacy shape)
      final engine = engineWith(remote);
      await engine.syncOnce(); // drains outbox; tombstone remains

      expect((await notes.getById(note.id))!.isDeleted, isTrue);

      // Backdate the tombstone past the retention window, then sync again.
      final sqlDb = await db.database;
      await sqlDb.rawUpdate(
        'UPDATE notes SET updated_at = ? WHERE id = ?',
        ['2020-01-01T00:00:00.000Z', note.id],
      );
      await engine.syncOnce();

      expect(await notes.getById(note.id), isNull);
    });
  });

  group('local search & filters', () {
    test('FTS search finds words and prefixes, and tracks updates', () async {
      expect(db.ftsAvailable, isTrue);

      final milk = await noteRepo.createNote(
          title: 'Groceries', content: 'buy milk and bread');
      await noteRepo.createNote(
          title: 'Meeting', content: 'quarterly planning session');

      expect(await notes.list(search: 'milk'), hasLength(1));
      expect(await notes.list(search: 'quarterly plan'), hasLength(1));
      expect(await notes.list(search: 'nonexistent'), isEmpty);
      // MATCH syntax can't be injected.
      expect(await notes.list(search: '"milk OR bread('), isEmpty);

      // Updating a note re-indexes it (INSERT OR REPLACE + triggers).
      await noteRepo.updateNote(milk.id, content: 'buy oat drink');
      expect(await notes.list(search: 'milk'), isEmpty);
      expect(await notes.list(search: 'oat'), hasLength(1));
    });

    test('tag filter matches whole names only', () async {
      await noteRepo.createNote(title: 'A', tagNames: ['work']);
      await noteRepo.createNote(title: 'B', tagNames: ['workout']);

      expect(await notes.list(tagName: 'work'), hasLength(1));
      expect(await notes.list(tagName: 'wor'), isEmpty);
      expect(await notes.list(tagName: '100%'), isEmpty); // wildcards escaped
    });

    test('archive and trash views are exclusive', () async {
      final a = await noteRepo.createNote(title: 'active');
      final b = await noteRepo.createNote(title: 'archived');
      final c = await noteRepo.createNote(title: 'trashed');
      await noteRepo.updateNote(b.id, isArchived: true);
      await noteRepo.deleteNote(c.id);

      final active = await notes.list();
      expect(active.map((n) => n.id), [a.id]);

      final archived = await notes.list(archived: true);
      expect(archived.map((n) => n.id), [b.id]);

      final trashed = await notes.list(archived: null, deleted: true);
      expect(trashed.map((n) => n.id), [c.id]);
    });
  });

  group('tag tombstones', () {
    test('LWW ignores an older server tag update over a newer local one',
        () async {
      final now = DateTime.now().toUtc();
      final created = Tag(
        id: 't1',
        userId: 'u1',
        name: 'temp',
        createdAt: now,
        updatedAt: now,
      );
      final sqlDb = await db.database;
      await sqlDb.transaction((txn) async {
        await tags.upsert(txn, created);
      });

      final stale = created.copyWith(
        name: 'renamed elsewhere',
        updatedAt: created.updatedAt.subtract(const Duration(hours: 1)),
      );
      await sqlDb.transaction((txn) async {
        await tags.applyServerTags(txn, [stale]);
      });

      expect((await tags.getById('t1'))!.name, 'temp');
    });
  });
}
