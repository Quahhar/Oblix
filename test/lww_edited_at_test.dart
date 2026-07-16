// The server's LWW basis is edited_at (when a human last edited), while
// updated_at is the server APPLY time. The client must merge by edited_at, or
// an older edit that merely synced later would clobber a newer local edit
// until the next push round-trips (a visible content flash).

import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/db/app_database.dart';
import 'package:oblix/core/db/meta_dao.dart';
import 'package:oblix/data/datasources/local/note_local_datasource.dart';
import 'package:oblix/data/models/note.dart';
import 'package:oblix/data/repositories/note_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, dynamic> _serverNote(
  String id, {
  required String title,
  required DateTime editedAt,
  required DateTime updatedAt,
}) =>
    {
      'id': id,
      'user_id': 'u1',
      'title': title,
      'content': '',
      'content_type': 'plain',
      'is_pinned': false,
      'is_archived': false,
      'is_deleted': false,
      'created_at': editedAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'edited_at': editedAt.toIso8601String(),
      'tags': const <dynamic>[],
    };

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late NoteLocalDataSource notes;
  late NoteRepository repo;

  setUp(() async {
    db = AppDatabase.ephemeral(
      dbFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    notes = NoteLocalDataSource(db);
    repo = NoteRepository(appDb: db);
    await MetaDao(db).setUserId('u1');
  });

  tearDown(() => db.close());

  test('fromJson prefers edited_at over updated_at as the local edit time',
      () {
    final edited = DateTime.utc(2026, 7, 16, 10, 0);
    final applied = DateTime.utc(2026, 7, 16, 10, 5);
    final note = Note.fromJson(
      _serverNote('n1', title: 't', editedAt: edited, updatedAt: applied),
    );
    expect(note.updatedAt, edited);
  });

  test('fromJson falls back to updated_at when edited_at is absent', () {
    final applied = DateTime.utc(2026, 7, 16, 10, 5);
    final json =
        _serverNote('n1', title: 't', editedAt: applied, updatedAt: applied)
          ..remove('edited_at');
    expect(Note.fromJson(json).updatedAt, applied);
  });

  test(
      'an older edit synced later (newer updated_at) cannot clobber a newer '
      'local edit', () async {
    // Local edit at T+3min.
    final local = await repo.createNote(title: 'newer local edit');

    // Another device edited 3 minutes EARLIER, but the server applied it just
    // now — so its updated_at is newer than our edit while its edited_at is
    // older. LWW by edited_at must keep the local version.
    final stale = Note.fromJson(_serverNote(
      local.id,
      title: 'older remote edit',
      editedAt: local.updatedAt.subtract(const Duration(minutes: 3)),
      updatedAt: DateTime.now().toUtc().add(const Duration(seconds: 1)),
    ));

    final sqfDb = await db.database;
    await sqfDb.transaction((txn) async {
      await notes.applyServerNotes(txn, [stale]);
    });

    expect((await notes.getById(local.id))!.title, 'newer local edit');
  });

  test('a genuinely newer remote edit still wins', () async {
    final local = await repo.createNote(title: 'old local');
    final newer = Note.fromJson(_serverNote(
      local.id,
      title: 'newer remote edit',
      editedAt: local.updatedAt.add(const Duration(minutes: 3)),
      updatedAt: DateTime.now().toUtc(),
    ));

    final sqfDb = await db.database;
    await sqfDb.transaction((txn) async {
      await notes.applyServerNotes(txn, [newer]);
    });

    expect((await notes.getById(local.id))!.title, 'newer remote edit');
  });
}
