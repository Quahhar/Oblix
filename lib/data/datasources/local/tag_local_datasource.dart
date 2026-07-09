import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../models/tag.dart';

/// Local SQLite access for tags (offline-first mirror).
///
/// Note: the server hard-deletes tags, so a tag deleted on another device is
/// not currently signalled through pull — this mirror learns about creates and
/// renames, not remote deletions. (Tracked as a known gap; would need tombstones
/// or soft-delete on the server.)
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

  Future<List<Tag>> list() async {
    final db = await _appDb.database;
    final rows = await db.query('tags', orderBy: 'name ASC');
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

  /// Apply server tags with last-write-wins on `updated_at`.
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

  Map<String, Object?> _toRow(Tag t) => {
    'id': t.id,
    'user_id': t.userId,
    'name': t.name,
    'created_at': t.createdAt.toUtc().toIso8601String(),
    'updated_at': t.updatedAt.toUtc().toIso8601String(),
  };

  Tag _fromRow(Map<String, Object?> r) => Tag(
    id: r['id'] as String,
    userId: r['user_id'] as String,
    name: r['name'] as String? ?? '',
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );
}
