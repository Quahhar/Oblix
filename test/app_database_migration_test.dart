import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oblix/core/db/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'v4 direct upgrade adds and backfills every CRDT clock column',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'oblix-v4-upgrade-',
      );
      final path = '${directory.path}${Platform.pathSeparator}oblix.db';
      AppDatabase? upgraded;
      try {
        final legacy = await databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 4,
            onCreate: (db, _) async {
              await db.execute('''
              CREATE TABLE notes (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                updated_at TEXT NOT NULL
              )
            ''');
              await db.execute('''
              CREATE TABLE notebooks (
                id TEXT PRIMARY KEY,
                updated_at TEXT NOT NULL
              )
            ''');
            },
          ),
        );
        const timestamp = '2026-08-01T12:00:00.000Z';
        await legacy.insert('notes', {
          'id': 'note-1',
          'title': 'Legacy note',
          'content': 'Body',
          'updated_at': timestamp,
        });
        await legacy.insert('notebooks', {
          'id': 'notebook-1',
          'updated_at': timestamp,
        });
        await legacy.close();

        upgraded = AppDatabase.ephemeral(
          dbFactory: databaseFactoryFfi,
          path: path,
        );
        final db = await upgraded.database;

        for (final table in const ['notes', 'notebooks', 'tasks']) {
          final columns = await db.rawQuery('PRAGMA table_info($table)');
          expect(
            columns.map((column) => column['name']),
            contains('field_clocks'),
          );
        }

        final noteClocks =
            jsonDecode(
                  (await db.query(
                        'notes',
                        columns: ['field_clocks'],
                      )).single['field_clocks']!
                      as String,
                )
                as Map<String, dynamic>;
        expect(noteClocks.keys.toSet(), {
          'title',
          'content',
          'content_type',
          'notebook_id',
          'is_pinned',
          'is_archived',
          'tags',
          'is_deleted',
        });
        expect(noteClocks['title'], {
          'timestamp': timestamp,
          'device_id': 'legacy',
        });

        final notebookClocks =
            jsonDecode(
                  (await db.query(
                        'notebooks',
                        columns: ['field_clocks'],
                      )).single['field_clocks']!
                      as String,
                )
                as Map<String, dynamic>;
        expect(notebookClocks.keys.toSet(), {
          'name',
          'parent_id',
          'sort_order',
          'is_deleted',
        });
      } finally {
        await upgraded?.close();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    },
  );
}
