import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../models/notebook.dart';

/// Local SQLite access for notebooks (offline-first mirror).
class NotebookLocalDataSource {
  final AppDatabase _appDb;
  NotebookLocalDataSource(this._appDb);

  Future<Notebook?> getById(String id) async {
    final db = await _appDb.database;
    final rows =
        await db.query('notebooks', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<List<Notebook>> list({bool includeDeleted = false}) async {
    final db = await _appDb.database;
    final rows = await db.query(
      'notebooks',
      where: includeDeleted ? null : 'is_deleted = 0',
      orderBy: 'sort_order ASC, name ASC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<void> upsert(DatabaseExecutor db, Notebook nb) async {
    await db.insert(
      'notebooks',
      _toRow(nb),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Apply server notebooks with last-write-wins on `updated_at`.
  Future<int> applyServerNotebooks(
    Transaction txn,
    List<Notebook> serverNotebooks,
  ) async {
    var applied = 0;
    for (final server in serverNotebooks) {
      final rows = await txn.query(
        'notebooks',
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
      'notebooks',
      where: 'is_deleted = 1 AND updated_at < ? '
          'AND id NOT IN (SELECT entity_id FROM outbox)',
      whereArgs: [cutoffUtc.toIso8601String()],
    );
  }

  Map<String, Object?> _toRow(Notebook n) => {
    'id': n.id,
    'user_id': n.userId,
    'name': n.name,
    'parent_id': n.parentId,
    'sort_order': n.sortOrder,
    'is_deleted': n.isDeleted ? 1 : 0,
    'created_at': n.createdAt.toUtc().toIso8601String(),
    'updated_at': n.updatedAt.toUtc().toIso8601String(),
  };

  Notebook _fromRow(Map<String, Object?> r) => Notebook(
    id: r['id'] as String,
    userId: r['user_id'] as String,
    name: r['name'] as String? ?? '',
    parentId: r['parent_id'] as String?,
    sortOrder: r['sort_order'] as int? ?? 0,
    isDeleted: (r['is_deleted'] as int? ?? 0) == 1,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );
}
