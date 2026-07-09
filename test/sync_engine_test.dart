// End-to-end tests for the offline-first sync engine, run against a real (but
// in-memory) SQLite database via sqflite_common_ffi — no device or network.
//
// These exercise the contract that matters for correctness:
//   * local writes land in the DB and the outbox,
//   * a sync cycle pushes the outbox, merges server changes, advances the
//     cursor, and drains exactly the pushed batch,
//   * last-write-wins protects a newer local edit from an older server version.

import 'package:cyclux/core/db/app_database.dart';
import 'package:cyclux/core/db/meta_dao.dart';
import 'package:cyclux/data/datasources/local/note_local_datasource.dart';
import 'package:cyclux/data/datasources/local/notebook_local_datasource.dart';
import 'package:cyclux/data/datasources/local/outbox_dao.dart';
import 'package:cyclux/data/datasources/local/tag_local_datasource.dart';
import 'package:cyclux/data/datasources/remote/sync_remote_datasource.dart';
import 'package:cyclux/data/models/sync_payload.dart';
import 'package:cyclux/data/repositories/note_repository.dart';
import 'package:cyclux/domain/usecases/sync_notes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Fake transport: records what was pushed and returns a scripted response.
class _FakeRemote extends SyncRemoteDataSource {
  _FakeRemote(this.response);

  final SyncPushResponse response;
  List<SyncChangeItem>? lastPushed;
  String? lastCursor;

  @override
  Future<SyncPushResponse> pushChanges({
    required List<SyncChangeItem> changes,
    String? lastSyncAt,
  }) async {
    lastPushed = changes;
    lastCursor = lastSyncAt;
    return response;
  }
}

Map<String, dynamic> _noteChange(
  String id, {
  required String title,
  required DateTime updatedAt,
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
      'tags': <dynamic>[],
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

Map<String, dynamic> _tagChange(String id, String name, DateTime at) {
  final iso = at.toUtc().toIso8601String();
  return {
    'entity_type': 'tag',
    'entity_id': id,
    'action': 'update',
    'data': {
      'id': id,
      'user_id': 'u1',
      'name': name,
      'created_at': iso,
      'updated_at': iso,
    },
  };
}

SyncPushResponse _resp({
  List<Map<String, dynamic>> serverChanges = const [],
  String serverTime = '',
}) =>
    SyncPushResponse(
      applied: const [],
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

  SyncEngine engineWith(_FakeRemote remote) => SyncEngine(
        appDb: db,
        remote: remote,
        outbox: outbox,
        notes: notes,
        notebooks: notebooks,
        tags: tags,
        meta: meta,
      );

  test('local create writes note and enqueues one outbox entry', () async {
    final note = await noteRepo.createNote(title: 'A');

    expect(await outbox.pendingCount(), 1);
    final stored = await notes.getById(note.id);
    expect(stored, isNotNull);
    expect(stored!.title, 'A');
  });

  test('sync pushes outbox, merges server entities, advances cursor, drains',
      () async {
    final local = await noteRepo.createNote(title: 'local');

    final remote = _FakeRemote(_resp(
      serverChanges: [
        _noteChange('srv-note', title: 'from server', updatedAt: DateTime.now()),
        _notebookChange('srv-nb', 'Inbox', DateTime.now()),
        _tagChange('srv-tag', 'work', DateTime.now()),
      ],
      serverTime: '2026-07-09T12:00:00.000Z',
    ));

    final result = await engineWith(remote).syncOnce();

    expect(result.success, isTrue);
    expect(result.pushed, 1);
    expect(result.pulled, 3); // note + notebook + tag

    // The local note was the thing pushed.
    expect(remote.lastPushed, isNotNull);
    expect(remote.lastPushed!.single.entityId, local.id);
    expect(remote.lastCursor, isNull); // first sync has no prior cursor

    // Outbox drained, cursor advanced.
    expect(await outbox.pendingCount(), 0);
    expect(await meta.getCursor(), '2026-07-09T12:00:00.000Z');

    // Server entities merged into their local mirrors.
    expect(await notes.getById('srv-note'), isNotNull);
    expect((await notebooks.getById('srv-nb'))!.name, 'Inbox');
    expect((await tags.getById('srv-tag'))!.name, 'work');
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
    final remote = _FakeRemote(_resp(
      serverChanges: [stale],
      serverTime: '2026-07-09T12:00:00.000Z',
    ));

    await engineWith(remote).syncOnce();

    final merged = await notes.getById(local.id);
    expect(merged!.title, 'newer local'); // local edit preserved
  });

  test('transport failure leaves outbox and cursor untouched', () async {
    await noteRepo.createNote(title: 'A');

    final failing = _ThrowingRemote();
    final engine = SyncEngine(
      appDb: db,
      remote: failing,
      outbox: outbox,
      notes: notes,
      notebooks: notebooks,
      tags: tags,
      meta: meta,
    );

    final result = await engine.syncOnce();

    expect(result.success, isFalse);
    expect(await outbox.pendingCount(), 1); // still queued for retry
    expect(await meta.getCursor(), isNull); // cursor not advanced
  });
}

class _ThrowingRemote extends SyncRemoteDataSource {
  @override
  Future<SyncPushResponse> pushChanges({
    required List<SyncChangeItem> changes,
    String? lastSyncAt,
  }) async {
    throw Exception('network down');
  }
}
