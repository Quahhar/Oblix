// Tests for the offline-first attachment layer against a real in-memory SQLite
// database (sqflite_common_ffi) plus a temp dir for the cached bytes and a fake
// /files transport. Covers the parts that carry correctness:
//   * attach caches bytes on disk and records a local row,
//   * an attachment can't upload until its note has synced (outbox gate),
//   * processSync uploads pending files and settles tombstoned deletes,
//   * deleting a never-uploaded attachment drops it and its bytes outright.

import 'dart:io';

import 'package:oblix/core/db/app_database.dart';
import 'package:oblix/core/db/meta_dao.dart';
import 'package:oblix/data/datasources/local/attachment_local_datasource.dart';
import 'package:oblix/data/datasources/remote/files_remote_datasource.dart';
import 'package:oblix/data/repositories/attachment_repository.dart';
import 'package:oblix/data/repositories/note_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Records what was uploaded/deleted and returns scripted server responses.
class _FakeFiles extends FilesRemoteDataSource {
  final List<String> deleted = [];
  int _seq = 0;

  @override
  Future<Map<String, dynamic>> upload({
    required List<int> bytes,
    required String filename,
    String? mimeType,
    String? noteId,
  }) async {
    _seq++;
    return {
      'id': 'srv-file-$_seq',
      'filename': 'stored-$_seq.bin',
      'size_bytes': bytes.length,
    };
  }

  @override
  Future<void> delete(String fileId) async => deleted.add(fileId);

  @override
  Future<List<int>> download(String fileId) async => const [9, 9, 9];
}

void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late AttachmentLocalDataSource attachLocal;
  late MetaDao meta;
  late NoteRepository noteRepo;
  late AttachmentRepository repo;
  late _FakeFiles fake;
  late Directory tmp;

  setUp(() async {
    db = AppDatabase.ephemeral(
      dbFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    attachLocal = AttachmentLocalDataSource(db);
    meta = MetaDao(db);
    await meta.setUserId('u1');
    noteRepo = NoteRepository(appDb: db, meta: meta);
    fake = _FakeFiles();
    tmp = await Directory.systemTemp.createTemp('oblix_attach_test');
    repo = AttachmentRepository(
      appDb: db,
      local: attachLocal,
      meta: meta,
      remote: fake,
      attachmentsDir: () async => tmp,
    );
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test('attach caches bytes on disk and records a row', () async {
    final a = await repo.attach(
      noteId: 'note-1',
      bytes: const [1, 2, 3, 4],
      originalName: 'photo.png',
    );

    expect(a.isUploaded, isFalse);
    expect(a.sizeBytes, 4);
    expect(a.mimeType, 'image/png');
    expect(File(a.localPath!).existsSync(), isTrue);
    expect(await File(a.localPath!).readAsBytes(), [1, 2, 3, 4]);

    final list = await attachLocal.listForNote('note-1');
    expect(list.single.id, a.id);
  });

  test('an attachment cannot upload until its note has synced', () async {
    final note = await noteRepo.createNote(title: 'N'); // outbox: create
    await repo.attach(
      noteId: note.id,
      bytes: const [1, 2, 3],
      originalName: 'a.txt',
    );

    // The note's create is still queued → the file is not yet uploadable.
    expect(await attachLocal.pendingUploads(), isEmpty);

    // Simulate the note reaching the server (its outbox entry drained).
    final database = await db.database;
    await database.delete('outbox');

    final pending = await attachLocal.pendingUploads();
    expect(pending.single.noteId, note.id);
  });

  test('processSync uploads pending files and marks them uploaded', () async {
    final note = await noteRepo.createNote(title: 'N');
    final a = await repo.attach(
      noteId: note.id,
      bytes: const [1, 2, 3, 4, 5],
      originalName: 'a.bin',
    );
    (await db.database).delete('outbox'); // note synced

    final result = await repo.processSync();

    expect(result.uploaded, 1);
    final stored = await attachLocal.getById(a.id);
    expect(stored!.isUploaded, isTrue);
    expect(stored.remoteId, 'srv-file-1');
    expect(stored.sizeBytes, 5);
  });

  test('deleting an uploaded attachment tombstones, then processSync deletes '
      'the server file', () async {
    final note = await noteRepo.createNote(title: 'N');
    final a = await repo.attach(
      noteId: note.id,
      bytes: const [1, 2, 3],
      originalName: 'a.bin',
    );
    await (await db.database).delete('outbox');
    await repo.processSync(); // now uploaded, remoteId set

    final uploaded = await attachLocal.getById(a.id);
    await repo.delete(uploaded!);

    // Tombstone remains, queued for a server delete.
    expect((await attachLocal.pendingRemoteDeletes()).single.id, a.id);

    await repo.processSync();

    expect(fake.deleted, contains('srv-file-1'));
    expect(await attachLocal.getById(a.id), isNull); // row gone once acked
  });

  test('deleting a never-uploaded attachment removes it and its bytes',
      () async {
    final a = await repo.attach(
      noteId: 'note-1',
      bytes: const [1, 2, 3],
      originalName: 'a.bin',
    );
    final path = a.localPath!;
    expect(File(path).existsSync(), isTrue);

    await repo.delete(a);

    expect(File(path).existsSync(), isFalse);
    expect(await attachLocal.listForNote('note-1'), isEmpty);
  });
}
