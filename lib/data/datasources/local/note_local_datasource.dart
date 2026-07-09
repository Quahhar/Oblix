import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../models/note.dart';

/// Local SQLite access for notes. This is what the UI reads from and writes to;
/// the server is reconciled separately by the sync engine.
class NoteLocalDataSource {
  final AppDatabase _appDb;
  NoteLocalDataSource(this._appDb);

  // --- Reads ---

  Future<Note?> getById(String id) async {
    final db = await _appDb.database;
    final rows =
        await db.query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// List notes with the common filters. Excludes deleted/archived by default,
  /// pinned first, newest first — mirroring the server's ordering.
  Future<List<Note>> list({
    String? notebookId,
    bool includeArchived = false,
    bool includeDeleted = false,
    String? search,
  }) async {
    final db = await _appDb.database;
    final where = <String>[];
    final args = <Object?>[];

    if (!includeDeleted) where.add('is_deleted = 0');
    if (!includeArchived) where.add('is_archived = 0');
    if (notebookId != null) {
      where.add('notebook_id = ?');
      args.add(notebookId);
    }
    if (search != null && search.isNotEmpty) {
      where.add('(title LIKE ? OR content LIKE ?)');
      args.add('%$search%');
      args.add('%$search%');
    }

    final rows = await db.query(
      'notes',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'is_pinned DESC, updated_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  // --- Writes (run within a caller-supplied transaction) ---

  Future<void> upsert(DatabaseExecutor db, Note note) async {
    await db.insert(
      'notes',
      _toRow(note),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Apply notes pulled from the server using last-write-wins: a server note
  /// overwrites the local row only if it is at least as new. This protects a
  /// local edit made after the sync batch was assembled from being clobbered by
  /// an older server version.
  Future<int> applyServerNotes(Transaction txn, List<Note> serverNotes) async {
    var applied = 0;
    for (final server in serverNotes) {
      final rows = await txn.query(
        'notes',
        columns: ['updated_at'],
        where: 'id = ?',
        whereArgs: [server.id],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final localUpdated =
            DateTime.tryParse(rows.first['updated_at'] as String? ?? '');
        if (localUpdated != null &&
            server.updatedAt.toUtc().isBefore(localUpdated.toUtc())) {
          continue; // local is newer — keep it, it'll be pushed next cycle
        }
      }
      await upsert(txn, server);
      applied++;
    }
    return applied;
  }

  // --- Mapping ---

  Map<String, Object?> _toRow(Note n) => {
    'id': n.id,
    'user_id': n.userId,
    'notebook_id': n.notebookId,
    'title': n.title,
    'content': n.content,
    'content_type': n.contentType,
    'is_pinned': n.isPinned ? 1 : 0,
    'is_archived': n.isArchived ? 1 : 0,
    'is_deleted': n.isDeleted ? 1 : 0,
    'created_at': n.createdAt.toUtc().toIso8601String(),
    'updated_at': n.updatedAt.toUtc().toIso8601String(),
    'tags': jsonEncode(n.tagNames),
  };

  Note _fromRow(Map<String, Object?> r) {
    final tagsRaw = r['tags'] as String? ?? '[]';
    final tagNames = (jsonDecode(tagsRaw) as List)
        .map((e) => e.toString())
        .toList();
    return Note(
      id: r['id'] as String,
      userId: r['user_id'] as String,
      notebookId: r['notebook_id'] as String?,
      title: r['title'] as String? ?? 'Untitled',
      content: r['content'] as String? ?? '',
      contentType: r['content_type'] as String? ?? 'plain',
      isPinned: (r['is_pinned'] as int? ?? 0) == 1,
      isArchived: (r['is_archived'] as int? ?? 0) == 1,
      isDeleted: (r['is_deleted'] as int? ?? 0) == 1,
      createdAt: DateTime.parse(r['created_at'] as String),
      updatedAt: DateTime.parse(r['updated_at'] as String),
      tagNames: tagNames,
    );
  }
}
