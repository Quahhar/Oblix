import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../models/task.dart';

class TaskLocalDataSource {
  final AppDatabase _appDb;
  TaskLocalDataSource(this._appDb);

  Future<Task?> getById(String id) async {
    final db = await _appDb.database;
    final rows = await db.query(
      'tasks',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

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
      orderBy:
          'due_date IS NULL, due_date ASC, sort_order ASC, created_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  Future<int> countOpen() async {
    final db = await _appDb.database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM tasks WHERE is_deleted = 0 AND is_completed = 0',
          ),
        ) ??
        0;
  }

  Future<void> upsert(DatabaseExecutor db, Task task) async {
    await db.insert(
      'tasks',
      _toRow(task),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Join the server and local LWW maps. Concurrent changes to separate fields
  /// survive, while same-field changes converge by timestamp then device id.
  Future<int> applyServerTasks(Transaction txn, List<Task> serverTasks) async {
    var applied = 0;
    for (final server in serverTasks) {
      final rows = await txn.query(
        'tasks',
        where: 'id = ?',
        whereArgs: [server.id],
        limit: 1,
      );
      final merged = rows.isEmpty
          ? server
          : _fromRow(rows.first).mergeCrdt(server);
      await upsert(txn, merged);
      applied++;
    }
    return applied;
  }

  Future<int> purgeDeletedBefore(DatabaseExecutor db, DateTime cutoffUtc) {
    return db.delete(
      'tasks',
      where:
          'is_deleted = 1 AND updated_at < ? '
          'AND id NOT IN (SELECT entity_id FROM outbox)',
      whereArgs: [cutoffUtc.toIso8601String()],
    );
  }

  Map<String, Object?> _toRow(Task task) => {
    'id': task.id,
    'user_id': task.userId,
    'note_id': task.noteId,
    'title': task.title,
    'description': task.description,
    'is_completed': task.isCompleted ? 1 : 0,
    'completed_at': task.completedAt?.toUtc().toIso8601String(),
    'due_date': task.dueDate?.toUtc().toIso8601String(),
    'sort_order': task.sortOrder,
    'is_deleted': task.isDeleted ? 1 : 0,
    'created_at': task.createdAt.toUtc().toIso8601String(),
    'updated_at': task.updatedAt.toUtc().toIso8601String(),
    'field_clocks': jsonEncode(
      task.fieldClocks.map((field, clock) => MapEntry(field, clock.toJson())),
    ),
  };

  Task _fromRow(Map<String, Object?> row) => Task(
    id: row['id'] as String,
    userId: row['user_id'] as String,
    noteId: row['note_id'] as String?,
    title: row['title'] as String? ?? 'Untitled task',
    description: row['description'] as String? ?? '',
    isCompleted: (row['is_completed'] as int? ?? 0) == 1,
    completedAt: DateTime.tryParse(row['completed_at'] as String? ?? ''),
    dueDate: DateTime.tryParse(row['due_date'] as String? ?? ''),
    sortOrder: row['sort_order'] as int? ?? 0,
    isDeleted: (row['is_deleted'] as int? ?? 0) == 1,
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
    fieldClocks: _decodeFieldClocks(row['field_clocks']),
  );

  static Map<String, TaskCrdtClock> _decodeFieldClocks(Object? raw) {
    if (raw is! String || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.map<String, TaskCrdtClock>(
        (field, value) => MapEntry(
          field.toString(),
          TaskCrdtClock.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
    } on Object {
      return const {};
    }
  }
}
