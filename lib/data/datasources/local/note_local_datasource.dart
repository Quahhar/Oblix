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

  /// List notes with the common filters, pinned first, newest first —
  /// mirroring the server's ordering.
  ///
  /// [archived]/[deleted] are tri-state: false (default) excludes those notes,
  /// true returns ONLY them (the Archive/Trash views), null ignores the flag.
  /// [search] uses the FTS5 index when available and falls back to LIKE.
  Future<List<Note>> list({
    String? notebookId,
    bool? archived = false,
    bool? deleted = false,
    String? search,
    String? tagName,
  }) async {
    final db = await _appDb.database;
    final where = <String>[];
    final args = <Object?>[];

    if (deleted != null) where.add('is_deleted = ${deleted ? 1 : 0}');
    if (archived != null) where.add('is_archived = ${archived ? 1 : 0}');
    if (notebookId != null) {
      where.add('notebook_id = ?');
      args.add(notebookId);
    }
    if (tagName != null && tagName.isNotEmpty) {
      // Tags are stored as a JSON array of names, so a name always appears
      // wrapped in double quotes.
      where.add("tags LIKE ? ESCAPE '\\'");
      args.add('%${_escapeLike(jsonEncode(tagName))}%');
    }
    if (search != null && search.trim().isNotEmpty) {
      final ftsQuery = _appDb.ftsAvailable ? _toFtsQuery(search) : null;
      if (ftsQuery != null) {
        where.add(
          'rowid IN (SELECT rowid FROM notes_fts WHERE notes_fts MATCH ?)',
        );
        args.add(ftsQuery);
      } else {
        where.add("(title LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')");
        final pattern = '%${_escapeLike(search.trim())}%';
        args.add(pattern);
        args.add(pattern);
      }
    }

    final rows = await db.query(
      'notes',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'is_pinned DESC, updated_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Escape LIKE wildcards in user input (used with `ESCAPE '\'`).
  static String _escapeLike(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Turn free text into an FTS5 MATCH expression: every token quoted (so
  /// input can't inject MATCH syntax), the last one as a prefix so search
  /// feels live while typing. Returns null if no usable tokens remain.
  static String? _toFtsQuery(String search) {
    final tokens = search
        .split(RegExp(r'\s+'))
        .map((t) => t.replaceAll('"', '').trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return null;
    final quoted = [
      for (var i = 0; i < tokens.length; i++)
        i == tokens.length - 1 ? '"${tokens[i]}"*' : '"${tokens[i]}"',
    ];
    return quoted.join(' ');
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

  /// Hard-delete tombstones older than [cutoffUtc] that have no pending outbox
  /// entry (i.e. the server already knows about the deletion). Keeps the trash
  /// from growing forever.
  Future<int> purgeDeletedBefore(DatabaseExecutor db, DateTime cutoffUtc) {
    return db.delete(
      'notes',
      where: 'is_deleted = 1 AND updated_at < ? '
          'AND id NOT IN (SELECT entity_id FROM outbox)',
      whereArgs: [cutoffUtc.toIso8601String()],
    );
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
