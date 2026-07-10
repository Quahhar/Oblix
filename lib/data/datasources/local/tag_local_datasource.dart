import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../models/tag.dart';

/// Local SQLite access for tags (offline-first mirror). Deletions are
/// tombstoned (is_deleted = 1) on both sides so they propagate across devices,
/// then purged locally after the retention window.
class TagLocalDataSource {
  final AppDatabase _appDb;
  TagLocalDataSource(this._appDb);

  Future<Tag?> getById(String id) async {
    final db = await _appDb.database;
    final rows =
        await db.query('tags', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<List<Tag>> list({bool includeDeleted = false}) async {
    final db = await _appDb.database;
    final rows = await db.query(
      'tags',
      where: includeDeleted ? null : 'is_deleted = 0',
      orderBy: 'name ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> upsert(DatabaseExecutor db, Tag tag) async {
    await db.insert(
      'tags',
      _toRow(tag),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(DatabaseExecutor db, String id) async {
    await db.delete('tags', where: 'id = ?', whereArgs: [id]);
  }

  /// Apply server tags with last-write-wins on `updated_at`. Server tombstones
  /// (is_deleted) land here like any other update, which is how a tag deleted
  /// on another device disappears on this one.
  Future<int> applyServerTags(Transaction txn, List<Tag> serverTags) async {
    var applied = 0;
    for (final server in serverTags) {
      final rows = await txn.query(
        'tags',
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
          continue;
        }
      }
      await upsert(txn, server);
      applied++;
    }
    return applied;
  }

  /// Hard-delete synced tombstones older than [cutoffUtc].
  Future<int> purgeDeletedBefore(DatabaseExecutor db, DateTime cutoffUtc) {
    return db.delete(
      'tags',
      where: 'is_deleted = 1 AND updated_at < ? '
          'AND id NOT IN (SELECT entity_id FROM outbox)',
      whereArgs: [cutoffUtc.toIso8601String()],
    );
  }

  Map<String, Object?> _toRow(Tag t) => {
    'id': t.id,
    'user_id': t.userId,
    'name': t.name,
    'is_deleted': t.isDeleted ? 1 : 0,
    'created_at': t.createdAt.toUtc().toIso8601String(),
    'updated_at': t.updatedAt.toUtc().toIso8601String(),
  };

  Tag _fromRow(Map<String, Object?> r) => Tag(
    id: r['id'] as String,
    userId: r['user_id'] as String,
    name: r['name'] as String? ?? '',
    isDeleted: (r['is_deleted'] as int? ?? 0) == 1,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );
}
