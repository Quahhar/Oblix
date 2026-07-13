// Tests for import/export: ENEX parsing, the native .oblix round-trip, and
// importing end-to-end into a real (in-memory) SQLite store so the imported
// notes land in the notes table AND the outbox (i.e. they will sync).

import 'package:oblix/core/db/app_database.dart';
import 'package:oblix/core/db/meta_dao.dart';
import 'package:oblix/data/datasources/local/note_local_datasource.dart';
import 'package:oblix/data/datasources/local/outbox_dao.dart';
import 'package:oblix/data/io/enex_parser.dart';
import 'package:oblix/data/io/oblix_archive.dart';
import 'package:oblix/data/models/note.dart';
import 'package:oblix/data/models/notebook.dart';
import 'package:oblix/data/models/tag.dart';
import 'package:oblix/domain/services/import_export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _sampleEnex = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE en-export SYSTEM "http://xml.evernote.com/pub/evernote-export4.dtd">
<en-export export-date="20240101T000000Z" application="Evernote" version="10.0">
  <note>
    <title>Shopping list</title>
    <content><![CDATA[<?xml version="1.0"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note><div>Milk</div><div>Eggs</div><div>Bread</div></en-note>]]></content>
    <created>20230115T101500Z</created>
    <updated>20230116T110000Z</updated>
    <tag>groceries</tag>
    <tag>home</tag>
  </note>
  <note>
    <title>Meeting notes</title>
    <content><![CDATA[<en-note><div>Discuss roadmap</div><br/><div>Ship v1</div></en-note>]]></content>
    <created>20230201T090000Z</created>
    <tag>work</tag>
    <resource><data encoding="base64">AAAA</data><mime>image/png</mime></resource>
  </note>
</en-export>''';

void main() {
  group('EnexParser', () {
    test('parses notes, tags, timestamps and flattens ENML', () {
      final bundle = EnexParser.parse(_sampleEnex, notebookName: 'Imported');

      expect(bundle.noteCount, 2);
      expect(bundle.notebookNames, ['Imported']);

      final shopping = bundle.notes[0];
      expect(shopping.title, 'Shopping list');
      expect(shopping.content, 'Milk\nEggs\nBread'); // no blank lines between
      expect(shopping.tagNames, ['groceries', 'home']);
      expect(shopping.notebookName, 'Imported');
      expect(shopping.createdAt, DateTime.utc(2023, 1, 15, 10, 15, 0));
      expect(shopping.updatedAt, DateTime.utc(2023, 1, 16, 11, 0, 0));

      final meeting = bundle.notes[1];
      expect(meeting.content, 'Discuss roadmap\nShip v1');
      expect(meeting.tagNames, ['work']);
      // No <updated> → falls back to <created>.
      expect(meeting.updatedAt, DateTime.utc(2023, 2, 1, 9, 0, 0));
      // One <resource> that we can't import yet is counted.
      expect(meeting.skippedAttachments, 1);
    });

    test('malformed ENML still imports as stripped text', () {
      const enex = '''<en-export><note><title>Broken</title>
        <content><![CDATA[<en-note><div>Unclosed <b>bold</div></en-note>]]></content>
        <created>20230101T000000Z</created></note></en-export>''';
      final bundle = EnexParser.parse(enex);
      expect(bundle.noteCount, 1);
      expect(bundle.notes.single.content, contains('bold'));
    });
  });

  group('OblixArchive', () {
    test('encode → decode round-trips notes, tags and notebook links', () {
      final now = DateTime.utc(2026, 7, 13, 12, 0, 0);
      final notebooks = [
        Notebook(
          id: 'nb1',
          userId: 'u1',
          name: 'Work',
          createdAt: now,
          updatedAt: now,
        ),
      ];
      final notes = [
        Note(
          id: 'n1',
          userId: 'u1',
          notebookId: 'nb1',
          title: 'Hello',
          content: 'World',
          isPinned: true,
          createdAt: now,
          updatedAt: now,
          tagNames: const ['a', 'b'],
        ),
        Note(
          id: 'n2',
          userId: 'u1',
          title: 'Loose note',
          content: 'no notebook',
          createdAt: now,
          updatedAt: now,
        ),
      ];
      final tags = [
        Tag(id: 't1', userId: 'u1', name: 'a', createdAt: now, updatedAt: now),
      ];

      final bytes = OblixArchive.encode(
        notes: notes,
        notebooks: notebooks,
        tags: tags,
      );
      final bundle = OblixArchive.decode(bytes);

      expect(bundle.noteCount, 2);
      expect(bundle.notebookNames, ['Work']);
      final first = bundle.notes[0];
      expect(first.title, 'Hello');
      expect(first.content, 'World');
      expect(first.isPinned, true);
      expect(first.tagNames, ['a', 'b']);
      expect(first.notebookName, 'Work'); // linked by name, not id
      expect(bundle.notes[1].notebookName, isNull);
    });

    test('rejects a non-oblix archive', () {
      expect(
        () => OblixArchive.decode([1, 2, 3, 4]),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ImportExportService (end-to-end into SQLite)', () {
    late AppDatabase db;
    late MetaDao meta;
    late NoteLocalDataSource notes;
    late OutboxDao outbox;
    late ImportExportService service;

    setUpAll(sqfliteFfiInit);

    setUp(() async {
      db = AppDatabase.ephemeral(
        dbFactory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      meta = MetaDao(db);
      notes = NoteLocalDataSource(db);
      outbox = OutboxDao(db);
      await meta.setUserId('u1');
      service = ImportExportService(appDb: db);
    });

    tearDown(() async => db.close());

    test('ENEX import creates notes + outbox entries + a notebook', () async {
      final result = await service.importEnex(_sampleEnex, notebookName: 'Imported');

      expect(result.notesImported, 2);
      expect(result.notebooksCreated, 1);
      expect(result.skippedAttachments, 1);

      final stored = await notes.list(archived: null, deleted: false);
      expect(stored.length, 2);
      expect(stored.map((n) => n.title),
          containsAll(['Shopping list', 'Meeting notes']));
      // Every imported note carries its notebook and tags...
      expect(stored.every((n) => n.notebookId != null), isTrue);
      final shopping = stored.firstWhere((n) => n.title == 'Shopping list');
      expect(shopping.tagNames, ['groceries', 'home']);

      // ...and is queued to sync: 2 notes + 1 notebook = 3 outbox entries.
      expect(await outbox.pendingCount(), 3);
    });

    test('export then import round-trips through the store', () async {
      await service.importEnex(_sampleEnex, notebookName: 'Imported');
      final exported = await service.exportOblix();

      // Re-import into a fresh account: import always mints new notes.
      final db2 = AppDatabase.ephemeral(
        dbFactory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      final meta2 = MetaDao(db2);
      await meta2.setUserId('u2');
      final notes2 = NoteLocalDataSource(db2);
      final service2 = ImportExportService(appDb: db2);

      final result = await service2.importOblix(exported);
      expect(result.notesImported, 2);

      final stored = await notes2.list(archived: null, deleted: false);
      expect(stored.map((n) => n.title),
          containsAll(['Shopping list', 'Meeting notes']));
      final shopping = stored.firstWhere((n) => n.title == 'Shopping list');
      expect(shopping.tagNames, ['groceries', 'home']);
      expect(shopping.content, 'Milk\nEggs\nBread');
      await db2.close();
    });
  });
}
