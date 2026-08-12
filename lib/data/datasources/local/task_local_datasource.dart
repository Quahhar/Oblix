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

  /// Every live task, open and done.
  ///
  /// The Rust view engine decides what a screen shows — which day, which
  /// section, what order, which rows nest — so reading is deliberately dumb:
  /// hand it the whole working set once and let it plan. Splitting the query
  /// per tab is what made the old screen's "Scheduled" segment a lie, and it
  /// cannot compute subtask rollups or calendar density from a filtered slice
  /// anyway.
  ///
  /// Completed tasks are bounded by [completedSince] because the finished pile
  /// grows without limit while only the recent tail is ever rendered.
  Future<List<Task>> loadWorkingSet({
    DateTime? completedSince,
    String? notebookId,
  }) async {
    final db = await _appDb.database;
    final where = <String>['is_deleted = 0'];
    final args = <Object?>[];
    if (completedSince != null) {
      where.add('(is_completed = 0 OR completed_at >= ?)');
      args.add(completedSince.toUtc().toIso8601String());
    }
    if (notebookId != null) {
      where.add('notebook_id = ?');
      args.add(notebookId);
    }
    final rows = await db.query(
      'tasks',
      where: where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  /// [completed] tri-state: false = open, true = done, null = both.
  Future<List<Task>> list({
    bool? completed = false,
    bool scheduledOnly = false,
    String? noteId,
    String? notebookId,
    String? parentId,
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
    if (notebookId != null) {
      where.add('notebook_id = ?');
      args.add(notebookId);
    }
    if (parentId != null) {
      where.add('parent_id = ?');
      args.add(parentId);
    }
    final rows = await db.query(
      'tasks',
      where: where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy:
          'due_date IS NULL, due_date ASC, priority DESC, '
          'sort_order ASC, created_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Direct children of a task, for the rollup and for cascading completion.
  Future<List<Task>> childrenOf(String parentId) =>
      list(completed: null, parentId: parentId);

  Future<int> countOpen() async {
    final db = await _appDb.database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM tasks WHERE is_deleted = 0 AND is_completed = 0',
          ),
        ) ??
        0;
  }

  /// Tasks with a reminder still ahead of [from], for the notification
  /// scheduler to re-arm on launch. Bounded because the platform caps how many
  /// alarms one app may hold anyway.
  Future<List<Task>> pendingReminders(DateTime from, {int limit = 64}) async {
    final db = await _appDb.database;
    final rows = await db.query(
      'tasks',
      where:
          'is_deleted = 0 AND is_completed = 0 '
          'AND reminder_at IS NOT NULL AND reminder_at > ?',
      whereArgs: [from.toUtc().toIso8601String()],
      orderBy: 'reminder_at ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  /// The manual ranks currently stored for a set of tasks, so a drag can be
  /// planned without loading the rows themselves.
  Future<Map<String, int>> sortOrdersFor(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final db = await _appDb.database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'tasks',
      columns: ['id', 'sort_order'],
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    return {
      for (final row in rows)
        row['id'] as String: (row['sort_order'] as int? ?? 0),
    };
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
    'notebook_id': task.notebookId,
    'parent_id': task.parentId,
    'title': task.title,
    'description': task.description,
    'is_completed': task.isCompleted ? 1 : 0,
    'completed_at': task.completedAt?.toUtc().toIso8601String(),
    'due_date': task.dueDate?.toUtc().toIso8601String(),
    'due_has_time': task.dueHasTime ? 1 : 0,
    'priority': task.priority.value,
    'labels': jsonEncode(task.labels),
    'recurrence': task.recurrence,
    'reminder_at': task.reminderAt?.toUtc().toIso8601String(),
    'reminder_lead_minutes': task.reminderLeadMinutes,
    'sort_order': task.sortOrder,
    'is_deleted': task.isDeleted ? 1 : 0,
    'created_at': task.createdAt.toUtc().toIso8601String(),
    'updated_at': task.updatedAt.toUtc().toIso8601String(),
    'field_clocks': jsonEncode(
      task.fieldClocks.map((field, clock) => MapEntry(field, clock.toJson())),
    ),
  };

  Task _fromRow(Map<String, Object?> row) {
    final due = DateTime.tryParse(row['due_date'] as String? ?? '');
    return Task(
      id: row['id'] as String,
      userId: row['user_id'] as String,
      noteId: row['note_id'] as String?,
      notebookId: row['notebook_id'] as String?,
      parentId: row['parent_id'] as String?,
      title: row['title'] as String? ?? 'Untitled task',
      description: row['description'] as String? ?? '',
      isCompleted: (row['is_completed'] as int? ?? 0) == 1,
      completedAt: DateTime.tryParse(row['completed_at'] as String? ?? ''),
      dueDate: due,
      dueHasTime: (row['due_has_time'] as int? ?? 0) == 1 && due != null,
      priority: TaskPriority.fromValue(row['priority'] as int?),
      labels: Task.parseLabels(row['labels']),
      recurrence: _emptyToNull(row['recurrence'] as String?),
      reminderAt: DateTime.tryParse(row['reminder_at'] as String? ?? ''),
      reminderLeadMinutes: row['reminder_lead_minutes'] as int?,
      sortOrder: row['sort_order'] as int? ?? 0,
      isDeleted: (row['is_deleted'] as int? ?? 0) == 1,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      fieldClocks: _decodeFieldClocks(row['field_clocks']),
    );
  }

  static String? _emptyToNull(String? value) =>
      (value == null || value.isEmpty) ? null : value;

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
