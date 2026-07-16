import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../models/attachment.dart';

/// Local SQLite access for attachments. The UI reads/writes here; the bytes
/// live on disk (see AttachmentRepository), and uploads/downloads reconcile
/// with the server separately.
class AttachmentLocalDataSource {
  final AppDatabase _appDb;
  AttachmentLocalDataSource(this._appDb);

  Future<Attachment?> getById(String id) async {
    final db = await _appDb.database;
    final rows = await db
        .query('attachments', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Attachments for a note, newest first. Excludes tombstones by default.
  Future<List<Attachment>> listForNote(
    String noteId, {
    bool includeDeleted = false,
  }) async {
    final db = await _appDb.database;
    final where =
        includeDeleted ? 'note_id = ?' : 'note_id = ? AND is_deleted = 0';
    final rows = await db.query(
      'attachments',
      where: where,
      whereArgs: [noteId],
      orderBy: 'created_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> upsert(DatabaseExecutor db, Attachment a) async {
    await db.insert(
      'attachments',
      _toRow(a),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insert(Attachment a) async {
    final db = await _appDb.database;
    await upsert(db, a);
  }

  /// Local, not-yet-uploaded, non-deleted attachments whose owning note has
  /// already reached the server — i.e. no pending `create` for that note sits
  /// in the outbox. Uploading before the note exists would 404, so this gate is
  /// what enforces the note-before-file ordering.
  Future<List<Attachment>> pendingUploads() async {
    final db = await _appDb.database;
    final rows = await db.rawQuery('''
      SELECT * FROM attachments
      WHERE is_uploaded = 0
        AND is_deleted = 0
        AND local_path IS NOT NULL
        AND note_id NOT IN (
          SELECT entity_id FROM outbox WHERE action = 'create'
        )
      ORDER BY created_at ASC
    ''');
    return rows.map(_fromRow).toList();
  }

  /// Uploaded attachments the user asked to delete — their server file still
  /// needs a DELETE. (We keep the row until the deletion is acknowledged so a
  /// missed delete is retried.)
  Future<List<Attachment>> pendingRemoteDeletes() async {
    final db = await _appDb.database;
    final rows = await db.query(
      'attachments',
      where: 'is_deleted = 1 AND is_uploaded = 1 AND remote_id IS NOT NULL',
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> markUploaded(
    String id, {
    required String remoteId,
    required String filename,
    required int sizeBytes,
  }) async {
    final db = await _appDb.database;
    await db.update(
      'attachments',
      {
        'remote_id': remoteId,
        'filename': filename,
        'size_bytes': sizeBytes,
        'is_uploaded': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> setLocalPath(String id, String localPath) async {
    final db = await _appDb.database;
    await db.update(
      'attachments',
      {'local_path': localPath},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> softDelete(String id) async {
    final db = await _appDb.database;
    await db.update(
      'attachments',
      {
        'is_deleted': 1,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Hard-remove a row (after its server file is confirmed gone, or a never-
  /// uploaded local delete).
  Future<void> hardDelete(String id) async {
    final db = await _appDb.database;
    await db.delete('attachments', where: 'id = ?', whereArgs: [id]);
  }

  /// Reconcile a server file list into the local mirror. Server files we don't
  /// know (by remote_id) are inserted as not-yet-downloaded rows; server
  /// tombstones soft-delete the local row. Local-only rows (not yet uploaded)
  /// are never touched here.
  Future<int> applyServerFiles(
    DatabaseExecutor db,
    List<Attachment> serverFiles, {
    required String Function() newLocalId,
  }) async {
    var applied = 0;
    for (final server in serverFiles) {
      final existing = await db.query(
        'attachments',
        where: 'remote_id = ?',
        whereArgs: [server.remoteId],
        limit: 1,
      );
      if (existing.isEmpty) {
        if (server.isDeleted) continue; // nothing to create for a tombstone
        await upsert(db, server.copyWithLocalId(newLocalId()));
        applied++;
      } else if (server.isDeleted) {
        // The server already deleted this file — drop the row outright. It
        // must NOT become a local tombstone, or pendingRemoteDeletes would
        // re-issue a DELETE for a file that's already gone, 404 forever.
        // (Cached bytes on disk, if any, are swept opportunistically later.)
        await db.delete(
          'attachments',
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
        applied++;
      } else {
        final row = _fromRow(existing.first);
        // Keep our local bytes/path; just track relink + metadata.
        await db.update(
          'attachments',
          {
            'note_id': server.noteId.isEmpty ? row.noteId : server.noteId,
            'size_bytes': server.sizeBytes,
            'updated_at': server.updatedAt.toUtc().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [row.id],
        );
        applied++;
      }
    }
    return applied;
  }

  Map<String, Object?> _toRow(Attachment a) => {
    'id': a.id,
    'remote_id': a.remoteId,
    'note_id': a.noteId,
    'user_id': a.userId,
    'filename': a.filename,
    'original_name': a.originalName,
    'mime_type': a.mimeType,
    'size_bytes': a.sizeBytes,
    'local_path': a.localPath,
    'is_uploaded': a.isUploaded ? 1 : 0,
    'is_deleted': a.isDeleted ? 1 : 0,
    'created_at': a.createdAt.toUtc().toIso8601String(),
    'updated_at': a.updatedAt.toUtc().toIso8601String(),
  };

  Attachment _fromRow(Map<String, Object?> r) => Attachment(
    id: r['id'] as String,
    remoteId: r['remote_id'] as String?,
    noteId: r['note_id'] as String,
    userId: r['user_id'] as String? ?? '',
    filename: r['filename'] as String? ?? '',
    originalName: r['original_name'] as String? ?? 'file',
    mimeType: r['mime_type'] as String? ?? 'application/octet-stream',
    sizeBytes: r['size_bytes'] as int? ?? 0,
    localPath: r['local_path'] as String?,
    isUploaded: (r['is_uploaded'] as int? ?? 0) == 1,
    isDeleted: (r['is_deleted'] as int? ?? 0) == 1,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );
}

extension on Attachment {
  Attachment copyWithLocalId(String localId) => Attachment(
    id: localId,
    remoteId: remoteId,
    noteId: noteId,
    userId: userId,
    filename: filename,
    originalName: originalName,
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    localPath: localPath,
    isUploaded: isUploaded,
    isDeleted: isDeleted,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}
