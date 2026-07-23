// Tests for import/export: ENEX parsing, the native .oblix round-trip,
// markdown (md/txt) import/export, EPUB round-trip, and importing
// end-to-end into a real (in-memory) SQLite store.

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/db/app_database.dart';
import 'package:oblix/core/db/meta_dao.dart';
import 'package:oblix/data/datasources/local/note_local_datasource.dart';
import 'package:oblix/data/datasources/local/outbox_dao.dart';
import 'package:oblix/data/io/enex_parser.dart';
import 'package:oblix/data/io/epub_exporter.dart';
import 'package:oblix/data/io/epub_importer.dart';
import 'package:oblix/data/io/markdown_exporter.dart';
import 'package:oblix/data/io/markdown_importer.dart';
import 'package:oblix/data/io/oblix_archive.dart';
import 'package:oblix/data/io/text_exporter.dart';
import 'package:oblix/data/models/note.dart';
import 'package:oblix/data/models/notebook.dart';
import 'package:oblix/data/models/tag.dart';
import 'package:oblix/domain/services/import_export_service.dart';
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
      expect(shopping.content, 'Milk\nEggs\nBread');
      expect(shopping.tagNames, ['groceries', 'home']);
      expect(shopping.notebookName, 'Imported');
      expect(shopping.createdAt, DateTime.utc(2023, 1, 15, 10, 15, 0));
      expect(shopping.updatedAt, DateTime.utc(2023, 1, 16, 11, 0, 0));

      final meeting = bundle.notes[1];
      expect(meeting.content, 'Discuss roadmap\nShip v1');
      expect(meeting.tagNames, ['work']);
      expect(meeting.updatedAt, DateTime.utc(2023, 2, 1, 9, 0, 0));
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
    test(
      'encode → decode v2 round-trips notes, tags, notebook paths and attachments',
      () {
        final now = DateTime.utc(2026, 7, 13, 12, 0, 0);
        final parent = Notebook(
          id: 'nb1',
          userId: 'u1',
          name: 'Work',
          createdAt: now,
          updatedAt: now,
        );
        final child = Notebook(
          id: 'nb2',
          userId: 'u1',
          name: 'Projects',
          parentId: 'nb1',
          createdAt: now,
          updatedAt: now,
        );
        final notebooks = [parent, child];
        final notes = [
          Note(
            id: 'n1',
            userId: 'u1',
            notebookId: 'nb2',
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
          Tag(
            id: 't1',
            userId: 'u1',
            name: 'a',
            createdAt: now,
            updatedAt: now,
          ),
        ];

        final attBytes = utf8.encode('hello');
        final attachmentsByNoteId = {
          'n1': [
            OblixAttachment(
              id: 'att1',
              originalName: 'file.txt',
              mimeType: 'text/plain',
              bytes: attBytes,
            ),
          ],
        };

        final bytes = OblixArchive.encode(
          notes: notes,
          notebooks: notebooks,
          tags: tags,
          attachmentsByNoteId: attachmentsByNoteId,
        );
        final bundle = OblixArchive.decode(bytes);

        expect(bundle.noteCount, 2);
        expect(bundle.notebookPaths.length, 2);

        final first = bundle.notes[0];
        expect(first.title, 'Hello');
        expect(first.content, 'World');
        expect(first.isPinned, true);
        expect(first.tagNames, ['a', 'b']);
        expect(first.notebookPath, ['Work', 'Projects']);
        expect(first.attachments.length, 1);
        expect(first.attachments.first.originalName, 'file.txt');
        expect(first.attachments.first.bytes, attBytes);
        expect(bundle.notes[1].notebookPath, isNull);
      },
    );

    test('decode accepts v1 bundles (flat notebook_name, no files/)', () {
      // Build a genuine v1 archive by hand: manifest version 1, notes carry
      // a flat notebook_name, notebooks have no path, no files/ blobs. (The
      // current encoder always writes v2, so it can't produce this shape.)
      final manifest = utf8.encode(
        jsonEncode({'format': 'oblix-export', 'version': 1}),
      );
      final data = utf8.encode(
        jsonEncode({
          'notes': [
            {
              'title': 'Hello',
              'content': 'World',
              'content_type': 'plain',
              'tags': <String>[],
              'is_pinned': false,
              'is_archived': false,
              'notebook_name': 'Work',
              'created_at': '2026-07-13T12:00:00.000Z',
              'updated_at': '2026-07-13T12:00:00.000Z',
            },
          ],
          'notebooks': [
            {'name': 'Work', 'sort_order': 0},
          ],
          'tags': <String>[],
        }),
      );
      final archive = Archive()
        ..addFile(ArchiveFile('manifest.json', manifest.length, manifest))
        ..addFile(ArchiveFile('data.json', data.length, data));
      final bytes = ZipEncoder().encode(archive);

      final bundle = OblixArchive.decode(bytes);
      expect(bundle.noteCount, 1);
      expect(bundle.notes[0].notebookName, 'Work');
      expect(bundle.notes[0].notebookPath, isNull);
      expect(bundle.notebookNames, contains('Work'));
    });

    test('rejects a non-oblix archive', () {
      expect(
        () => OblixArchive.decode([1, 2, 3, 4]),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('MarkdownImporter', () {
    test('parses md with # heading as title', () {
      const md = '# My Title\n\nThis is the body.\nMore text.';
      final note = MarkdownImporter.parseOne(utf8.encode(md), 'test.md');
      expect(note.title, 'My Title');
      expect(note.content, 'This is the body.\nMore text.');
      expect(note.contentType, 'markdown');
    });

    test('parses txt with filename as title', () {
      const txt = 'Just plain text here.';
      final note = MarkdownImporter.parseOne(utf8.encode(txt), 'readme.txt');
      expect(note.title, 'readme');
      expect(note.content, 'Just plain text here.');
      expect(note.contentType, 'plain');
    });

    test('parses many files into one bundle', () {
      final files = [
        ('a.md', utf8.encode('# One\n\nBody one.')),
        ('b.txt', utf8.encode('Body two.')),
      ];
      final bundle = MarkdownImporter.parseMany(files);
      expect(bundle.noteCount, 2);
      expect(bundle.notes[0].title, 'One');
      expect(bundle.notes[1].title, 'b');
    });
  });

  group('MarkdownExporter', () {
    test('noteToMarkdown renders heading + body + tags', () {
      final note = Note(
        id: 'n1',
        userId: 'u1',
        title: 'Test',
        content: 'Hello world',
        tagNames: ['a', 'b'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final md = MarkdownExporter.noteToMarkdown(note);
      expect(md, contains('# Test'));
      expect(md, contains('Hello world'));
      expect(md, contains('Tags: a, b'));
    });

    test('notesToMarkdownZip produces valid ZIP bytes', () {
      final notes = [
        Note(
          id: 'n1',
          userId: 'u1',
          title: 'A',
          content: 'a',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];
      final zip = MarkdownExporter.notesToMarkdownZip(notes);
      expect(zip.isNotEmpty, true);
      // ZIP magic: "PK"
      expect(utf8.decode(zip.sublist(0, 2)), 'PK');
    });
  });

  group('TextExporter', () {
    test('noteToText renders title + body', () {
      final note = Note(
        id: 'n1',
        userId: 'u1',
        title: 'Test',
        content: 'Line1\nLine2',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final txt = TextExporter.noteToText(note);
      expect(txt, 'Test\n\nLine1\nLine2');
    });

    test('noteToText omits Untitled', () {
      final note = Note(
        id: 'n1',
        userId: 'u1',
        title: 'Untitled',
        content: 'Just body',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final txt = TextExporter.noteToText(note);
      expect(txt, 'Just body');
    });
  });

  group('Epub round-trip', () {
    test('export → import yields matching notes', () {
      final now = DateTime.utc(2026, 7, 14, 0, 0, 0);
      final notes = [
        Note(
          id: 'n1',
          userId: 'u1',
          title: 'Chapter One',
          content: 'First paragraph.\n\nSecond paragraph.',
          createdAt: now,
          updatedAt: now,
        ),
        Note(
          id: 'n2',
          userId: 'u1',
          title: 'Chapter Two',
          content: 'More text.',
          createdAt: now,
          updatedAt: now,
        ),
      ];

      final epubBytes = EpubExporter.notesToEpub(notes, now: now);
      expect(epubBytes.isNotEmpty, true);

      final bundle = EpubImporter.parse(epubBytes);
      expect(bundle.noteCount, 2);
      expect(bundle.notes[0].title, 'Chapter One');
      expect(bundle.notes[0].content, contains('First paragraph'));
      expect(bundle.notes[0].content, contains('Second paragraph'));
      expect(bundle.notes[1].title, 'Chapter Two');
      expect(bundle.notebookNames.isNotEmpty, true);
      // dc:title should be something export-like.
      expect(bundle.notebookNames.first, contains('Oblix export'));
    });

    test('mimetype entry is first and stored uncompressed (EPUB mandate)', () {
      final now = DateTime.utc(2026, 7, 13, 12, 0, 0);
      final notes = [
        Note(
          id: 'n1',
          userId: 'u1',
          title: 'Chapter One',
          content: 'Body.',
          createdAt: now,
          updatedAt: now,
        ),
      ];
      final zip = ZipDecoder().decodeBytes(
        EpubExporter.notesToEpub(notes, now: now),
      );
      expect(zip.files.first.name, 'mimetype');
      expect(zip.files.first.compression, CompressionType.none);
    });

    test('rejects non-EPUB archive', () {
      expect(
        () => EpubImporter.parse([1, 2, 3, 4]),
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
      final result = await service.importEnex(
        _sampleEnex,
        notebookName: 'Imported',
      );

      expect(result.notesImported, 2);
      expect(result.notebooksCreated, 1);
      expect(result.skippedAttachments, 1);

      final stored = await notes.list(archived: null, deleted: false);
      expect(stored.length, 2);
      expect(
        stored.map((n) => n.title),
        containsAll(['Shopping list', 'Meeting notes']),
      );
      expect(stored.every((n) => n.notebookId != null), isTrue);
      final shopping = stored.firstWhere((n) => n.title == 'Shopping list');
      expect(shopping.tagNames, ['groceries', 'home']);

      expect(await outbox.pendingCount(), 3); // 2 notes + 1 notebook
    });

    test('export then import round-trips through the store', () async {
      await service.importEnex(_sampleEnex, notebookName: 'Imported');
      final exported = await service.exportOblix();

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
      expect(
        stored.map((n) => n.title),
        containsAll(['Shopping list', 'Meeting notes']),
      );
      final shopping = stored.firstWhere((n) => n.title == 'Shopping list');
      expect(shopping.tagNames, ['groceries', 'home']);
      expect(shopping.content, 'Milk\nEggs\nBread');
      await db2.close();
    });

    test('Markdown import creates notes in store', () async {
      final files = [
        ('test.md', utf8.encode('# Alpha\n\nBody one.')),
        ('readme.txt', utf8.encode('Body two.')),
      ];
      final result = await service.importMarkdownFiles(files);
      expect(result.notesImported, 2);

      final stored = await notes.list(archived: null, deleted: false);
      expect(stored.length, 2);
      expect(stored.map((n) => n.title), containsAll(['Alpha', 'readme']));
    });

    test('EPUB import creates notes + notebook', () async {
      final epubNotes = [
        Note(
          id: 'n1',
          userId: 'u1',
          title: 'Ch1',
          content: 'First chapter text.\n\nParagraph two.',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];
      final epubBytes = EpubExporter.notesToEpub(epubNotes);

      final result = await service.importEpub(epubBytes);
      expect(result.notesImported, 1);
      expect(result.notebooksCreated, 1);

      final stored = await notes.list(archived: null, deleted: false);
      expect(stored.length, 1);
      expect(stored.first.title, 'Ch1');
      expect(stored.first.content, contains('First chapter text'));
    });
  });
}
