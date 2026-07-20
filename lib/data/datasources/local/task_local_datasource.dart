import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../models/task.dart';

/// Local SQLite access for tasks. Same shape as notes: the UI reads/writes
/// here, the sync engine reconciles with the server in the background.
class TaskLocalDataSource {
  final AppDatabase _appDb;
  TaskLocalDataSource(this._appDb);

  // --- Reads ---

  Future<Task?> getById(String id) async {
    final db = await _appDb.database;
    final rows =
        await db.query('tasks', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// List tasks. [completed] is tri-state: false/true filter by state, null
  /// returns both. [scheduledOnly] keeps only tasks with a due date (the
  /// "Scheduled" tab). Deleted tasks are always excluded (tasks have no trash
  /// view — a tombstone only exists to propagate the delete).
  ///
  /// Order: due date first (undated last), then manual sort order, then
  /// newest-created — so the Tasks screen can group rows top-to-bottom.
  Future<List<Task>> list({
    bool? completed = false,
    bool scheduledOnly = false,
    String? noteId,
  }) async {
    final db = await _appDb.database;
    final where = <String>['is_deleted = 0'];
    final args = <Object?>[];

    if (completed != null) where.add('is_completed = ${completed ? 1 : 0}');
    if (scheduledOnly) where.add('due_date IS NOT NULL');
    if (noteId != null) {
      where.add('note_id = ?');
      args.add(noteId);
    }

    final rows = await db.query(
      'tasks',
      where: where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'due_date IS NULL, due_date ASC, sort_order ASC, created_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<int> countOpen() async {
    final db = await _appDb.database;
    final n = Sqflite.firstIntValue(await db.rawQuery(
      'SELECT COUNT(*) FROM tasks WHERE is_deleted = 0 AND is_completed = 0',
    ));
    return n ?? 0;
  }

  // --- Writes (run within a caller-supplied transaction) ---

  Future<void> upsert(DatabaseExecutor db, Task task) async {
    await db.insert(
      'tasks',
      _toRow(task),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Apply tasks pulled from the server, last-write-wins by edit time — same
  /// rule as notes: a server task only overwrites a local row that is not
  /// newer, so an unsynced local edit survives the merge.
  Future<int> applyServerTasks(Transaction txn, List<Task> serverTasks) async {
    var applied = 0;
    for (final server in serverTasks) {
      final rows = await txn.query(
        'tasks',
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

  /// Hard-delete tombstones older than [cutoffUtc] with no pending outbox
  /// entry (the server already knows about the deletion).
  Future<int> purgeDeletedBefore(DatabaseExecutor db, DateTime cutoffUtc) {
    return db.delete(
      'tasks',
      where: 'is_deleted = 1 AND updated_at < ? '
          'AND id NOT IN (SELECT entity_id FROM outbox)',
      whereArgs: [cutoffUtc.toIso8601String()],
    );
  }

  // --- Mapping ---

  Map<String, Object?> _toRow(Task t) => {
    'id': t.id,
    'user_id': t.userId,
    'note_id': t.noteId,
    'title': t.title,
    'description': t.description,
    'is_completed': t.isCompleted ? 1 : 0,
    'completed_at': t.completedAt?.toUtc().toIso8601String(),
    'due_date': t.dueDate?.toUtc().toIso8601String(),
    'sort_order': t.sortOrder,
    'is_deleted': t.isDeleted ? 1 : 0,
    'created_at': t.createdAt.toUtc().toIso8601String(),
    'updated_at': t.updatedAt.toUtc().toIso8601String(),
  };

  Task _fromRow(Map<String, Object?> r) => Task(
    id: r['id'] as String,
    userId: r['user_id'] as String,
    noteId: r['note_id'] as String?,
    title: r['title'] as String? ?? 'Untitled task',
    description: r['description'] as String? ?? '',
    isCompleted: (r['is_completed'] as int? ?? 0) == 1,
    completedAt: DateTime.tryParse(r['completed_at'] as String? ?? ''),
    dueDate: DateTime.tryParse(r['due_date'] as String? ?? ''),
    sortOrder: r['sort_order'] as int? ?? 0,
    isDeleted: (r['is_deleted'] as int? ?? 0) == 1,
    createdAt: DateTime.parse(r['created_at'] as String),
    updatedAt: DateTime.parse(r['updated_at'] as String),
  );
}
