// Attachment lifecycle against a real in-memory SQLite database:
//
//   * attach() caches bytes + records a row immediately (offline-first),
//   * pendingUploads is gated on the owning note having reached the server
//     (its `create` no longer sitting in the outbox) — uploads before that
//     would 404 on the server's note link,
//   * processSync uploads pending files and settles tombstoned deletes,
//     treating a server-side 404 as "already done",
//   * applyServerFiles mirrors unknown server files in and hard-drops rows
//     the server tombstoned (never leaving a re-deletable ghost).

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/db/app_database.dart';
import 'package:oblix/core/db/meta_dao.dart';
import 'package:oblix/core/network/api_exceptions.dart';
import 'package:oblix/data/datasources/local/attachment_local_datasource.dart';
import 'package:oblix/data/datasources/local/outbox_dao.dart';
import 'package:oblix/data/datasources/remote/files_remote_datasource.dart';
import 'package:oblix/data/models/attachment.dart';
import 'package:oblix/data/repositories/attachment_repository.dart';
import 'package:oblix/data/repositories/note_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

class _FakeFilesRemote extends FilesRemoteDataSource {
  final uploads = <String>[]; // filenames uploaded
  final deletes = <String>[]; // remote ids deleted
  bool deleteThrows404 = false;
  int _n = 0;

  @override
  Future<Map<String, dynamic>> upload({
    required List<int> bytes,
    required String filename,
    String? mimeType,
    String? noteId,
  }) async {
    uploads.add(filename);
    _n++;
    return {
      'id': 'srv-file-$_n',
      'filename': 'generated-$_n.bin',
      'original_name': filename,
      'mime_type': mimeType ?? 'application/octet-stream',
      'size_bytes': bytes.length,
      'note_id': noteId,
    };
  }

  @override
  Future<void> delete(String fileId) async {
    if (deleteThrows404) throw NotFoundException('File not found');
    deletes.add(fileId);
  }

  @override
  Future<List<int>> download(String fileId) async => [1, 2, 3];
}

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late AttachmentLocalDataSource local;
  late OutboxDao outbox;
  late MetaDao meta;
  late NoteRepository notes;
  late _FakeFilesRemote remote;
  late AttachmentRepository repo;
  late Directory tempDir;

  setUp(() async {
    db = AppDatabase.ephemeral(
      dbFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    local = AttachmentLocalDataSource(db);
    outbox = OutboxDao(db);
    meta = MetaDao(db);
    notes = NoteRepository(appDb: db);
    remote = _FakeFilesRemote();
    tempDir = await Directory.systemTemp.createTemp('oblix_att_test');
    repo = AttachmentRepository(
      appDb: db,
      local: local,
      meta: meta,
      remote: remote,
      attachmentsDir: () async => tempDir,
    );
    await meta.setUserId('u1');
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  /// Ack every outbox entry, as a successful push would.
  Future<void> drainOutbox() async {
    final batch = await outbox.fetchBatch(limit: 1000);
    final sqfDb = await db.database;
    await sqfDb.transaction((txn) async {
      await outbox.settleBatch(
        txn,
        ackedSeqs: [for (final e in batch) e.seq],
        retrySeqs: const [],
        maxAttempts: 5,
      );
    });
  }

  test('attach caches bytes and records a local row', () async {
    final note = await notes.createNote(title: 'A');
    final a = await repo.attach(
      noteId: note.id,
      bytes: [104, 105],
      originalName: 'hi.txt',
    );

    expect(a.hasLocalBytes, isTrue);
    expect(await File(a.localPath!).readAsString(), 'hi');
    final listed = await repo.listForNote(note.id);
    expect(listed.single.originalName, 'hi.txt');
    expect(listed.single.isUploaded, isFalse);
    expect(listed.single.mimeType, 'text/plain');
  });

  test('pendingUploads waits for the note to reach the server', () async {
    final note = await notes.createNote(title: 'A');
    await repo.attach(noteId: note.id, bytes: [1], originalName: 'x.bin');

    // Note's `create` still queued -> the upload must wait.
    expect(await local.pendingUploads(), isEmpty);

    await drainOutbox(); // note acked by the server
    expect((await local.pendingUploads()).single.originalName, 'x.bin');
  });

  test('processSync uploads pending files and records the server identity',
      () async {
    final note = await notes.createNote(title: 'A');
    final a =
        await repo.attach(noteId: note.id, bytes: [1, 2], originalName: 'p.png');
    await drainOutbox();

    final result = await repo.processSync();

    expect(result.uploaded, 1);
    expect(remote.uploads, ['p.png']);
    final updated = (await repo.listForNote(note.id)).single;
    expect(updated.isUploaded, isTrue);
    expect(updated.remoteId, 'srv-file-1');
    expect(updated.id, a.id, reason: 'local id must stay stable');
  });

  test('delete of an uploaded file tombstones, then settles server-side',
      () async {
    final note = await notes.createNote(title: 'A');
    final a =
        await repo.attach(noteId: note.id, bytes: [1], originalName: 'd.bin');
    await drainOutbox();
    await repo.processSync(); // uploaded

    final uploaded = (await repo.listForNote(note.id)).single;
    await repo.delete(uploaded);
    expect(await repo.listForNote(note.id), isEmpty,
        reason: 'tombstone hidden from the note view');
    expect(await File(a.localPath!).exists(), isFalse,
        reason: 'local bytes removed immediately');

    final result = await repo.processSync();
    expect(result.deleted, 1);
    expect(remote.deletes, ['srv-file-1']);
    expect(await local.listForNote(note.id, includeDeleted: true), isEmpty,
        reason: 'row hard-deleted once the server ack came back');
  });

  test('a 404 on remote delete settles the tombstone (already gone)',
      () async {
    final note = await notes.createNote(title: 'A');
    await repo.attach(noteId: note.id, bytes: [1], originalName: 'g.bin');
    await drainOutbox();
    await repo.processSync();

    remote.deleteThrows404 = true;
    await repo.delete((await repo.listForNote(note.id)).single);
    final result = await repo.processSync();

    expect(result.deleted, 1);
    expect(result.failed, 0);
    expect(await local.listForNote(note.id, includeDeleted: true), isEmpty);
  });

  test('applyServerFiles mirrors new files in and hard-drops tombstones',
      () async {
    final sqfDb = await db.database;
    const uuid = Uuid();

    // A file another device uploaded.
    final fresh = Attachment.fromServerJson({
      'id': 'srv-9',
      'filename': 'gen.bin',
      'original_name': 'photo.jpg',
      'mime_type': 'image/jpeg',
      'size_bytes': 42,
      'note_id': 'note-1',
      'is_deleted': false,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, localId: '');
    await sqfDb.transaction((txn) async {
      await local.applyServerFiles(txn, [fresh], newLocalId: uuid.v4);
    });
    final mirrored = (await local.listForNote('note-1')).single;
    expect(mirrored.remoteId, 'srv-9');
    expect(mirrored.isUploaded, isTrue);
    expect(mirrored.hasLocalBytes, isFalse, reason: 'bytes not downloaded yet');

    // Same file now tombstoned on the server.
    final gone = Attachment.fromServerJson({
      'id': 'srv-9',
      'filename': 'gen.bin',
      'original_name': 'photo.jpg',
      'mime_type': 'image/jpeg',
      'size_bytes': 42,
      'note_id': 'note-1',
      'is_deleted': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, localId: '');
    await sqfDb.transaction((txn) async {
      await local.applyServerFiles(txn, [gone], newLocalId: uuid.v4);
    });
    expect(await local.listForNote('note-1', includeDeleted: true), isEmpty,
        reason: 'server tombstone removes the row entirely');
    expect(await local.pendingRemoteDeletes(), isEmpty,
        reason: 'must not re-issue a DELETE for a file the server removed');
  });
}
