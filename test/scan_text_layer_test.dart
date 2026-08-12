import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/db/app_database.dart';
import 'package:oblix/data/datasources/local/note_local_datasource.dart';
import 'package:oblix/data/datasources/local/outbox_dao.dart';
import 'package:oblix/data/repositories/note_repository.dart';
import 'package:oblix/core/db/meta_dao.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The half of scanning that does not need a recognizer.
///
/// Reconstruction, entity extraction and the text-layer format live in Rust
/// and are tested there; what is tested here is the storage those produce —
/// that the schema gains a place to keep a text layer, that the layer is
/// indexed, and above all that a note becomes findable by words that appear
/// only inside a photograph attached to it.
///
/// Rows are inserted directly rather than through `TextLayerRepository`,
/// because that repository encodes through the native core, which is not
/// loaded in unit tests. Going around it keeps this a test of the query rather
/// than of the bridge.
void main() {
  setUpAll(sqfliteFfiInit);

  late AppDatabase db;
  late NoteLocalDataSource notes;
  late NoteRepository noteRepo;

  setUp(() async {
    db = AppDatabase.ephemeral(
      dbFactory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    notes = NoteLocalDataSource(db);
    final meta = MetaDao(db);
    noteRepo = NoteRepository(
      appDb: db,
      local: notes,
      outbox: OutboxDao(db),
      meta: meta,
    );
    await meta.setUserId('u1');
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> addLayer({
    required String noteId,
    required String searchText,
    String fingerprint = '',
    String? attachmentId,
  }) async {
    final handle = await db.database;
    await handle.insert('text_layers', {
      'id': 'layer-$noteId-${searchText.hashCode}',
      'note_id': noteId,
      'attachment_id': attachmentId,
      'source': 'camera',
      'fingerprint': fingerprint,
      'search_text': searchText,
      'encoded': '{"v":1,"src":"camera","p":[]}',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  test('the schema gains somewhere to keep what the recognizer saw', () async {
    final handle = await db.database;
    final tables = await handle.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name IN ('text_layers', 'text_layers_fts')",
    );
    expect(tables.map((row) => row['name']), containsAll(<String>['text_layers']));
    expect(await handle.getVersion(), greaterThanOrEqualTo(7));
  });

  test('a note is found by words that appear only in its scan', () async {
    final note = await noteRepo.createNote(title: 'Receipt', content: '');
    await addLayer(noteId: note.id, searchText: 'Corner Grocer invoice 4471');

    final byImageWord = await notes.list(search: 'invoice');
    expect(byImageWord.map((n) => n.id), [note.id]);

    // And the note's own text still matches, which is the case that must not
    // regress now that the query has two halves.
    final byTitle = await notes.list(search: 'Receipt');
    expect(byTitle.map((n) => n.id), [note.id]);
  });

  test('a word in nobody\'s scan finds nothing', () async {
    final note = await noteRepo.createNote(title: 'Receipt', content: '');
    await addLayer(noteId: note.id, searchText: 'Corner Grocer');
    expect(await notes.list(search: 'aeroplane'), isEmpty);
  });

  test('scan hits still respect the archive and trash filters', () async {
    final note = await noteRepo.createNote(title: 'Filed', content: '');
    await addLayer(noteId: note.id, searchText: 'quarterly figures');
    expect(await notes.list(search: 'quarterly'), hasLength(1));

    await noteRepo.updateNote(note.id, isArchived: true);
    // The default list excludes archived notes, however they matched.
    expect(await notes.list(search: 'quarterly'), isEmpty);
    expect(await notes.list(search: 'quarterly', archived: true), hasLength(1));
  });

  test('a scan matches on a prefix, the way live typing searches', () async {
    final note = await noteRepo.createNote(title: 'Poster', content: '');
    await addLayer(noteId: note.id, searchText: 'Spring Concert');
    expect(await notes.list(search: 'conc'), hasLength(1));
  });

  test('two notes scanned with the same word both come back', () async {
    final first = await noteRepo.createNote(title: 'One', content: '');
    final second = await noteRepo.createNote(title: 'Two', content: '');
    await addLayer(noteId: first.id, searchText: 'shared word here');
    await addLayer(noteId: second.id, searchText: 'shared word too');
    final found = await notes.list(search: 'shared');
    expect(found.map((n) => n.id), unorderedEquals([first.id, second.id]));
  });

  test('deleting the layers stops the note matching on them', () async {
    final note = await noteRepo.createNote(title: 'Scan', content: '');
    await addLayer(noteId: note.id, searchText: 'ephemeral wording');
    expect(await notes.list(search: 'ephemeral'), hasLength(1));

    final handle = await db.database;
    await handle.delete(
      'text_layers',
      where: 'note_id = ?',
      whereArgs: [note.id],
    );
    expect(await notes.list(search: 'ephemeral'), isEmpty);
  });

  test('an attachment carries at most one layer', () async {
    final note = await noteRepo.createNote(title: 'Scan', content: '');
    await addLayer(
      noteId: note.id,
      searchText: 'first reading',
      attachmentId: 'att-1',
    );
    // The unique index is what lets the backfill pass be re-run safely: a
    // second reading of the same image cannot be stored twice.
    await expectLater(
      addLayer(
        noteId: note.id,
        searchText: 'second reading',
        attachmentId: 'att-1',
      ),
      throwsA(isA<DatabaseException>()),
    );
  });

  test('layers with no attachment do not collide with each other', () async {
    final note = await noteRepo.createNote(title: 'Scan', content: '');
    await addLayer(noteId: note.id, searchText: 'page one');
    await addLayer(noteId: note.id, searchText: 'page two');
    final handle = await db.database;
    final rows = await handle.query(
      'text_layers',
      where: 'note_id = ?',
      whereArgs: [note.id],
    );
    expect(rows, hasLength(2));
  });
}
