import 'dart:convert';

import 'package:equatable/equatable.dart';
import '../../core/native/oblix_core.dart';
import 'crdt_clock.dart';

typedef TaskCrdtClock = CrdtClock;

/// How much a task matters. Stored as an int so ordering is arithmetic and a
/// rank a future client invents degrades to [TaskPriority.none] here.
enum TaskPriority {
  none(0),
  low(1),
  high(2),
  urgent(3);

  const TaskPriority(this.value);
  final int value;

  static TaskPriority fromValue(int? raw) => switch (raw) {
    1 => TaskPriority.low,
    2 => TaskPriority.high,
    3 => TaskPriority.urgent,
    _ => TaskPriority.none,
  };

  /// What the user typed to get here, and what the row shows back.
  String get label => switch (this) {
    TaskPriority.none => 'No priority',
    TaskPriority.low => 'Priority 3',
    TaskPriority.high => 'Priority 2',
    TaskPriority.urgent => 'Priority 1',
  };
}

class Task extends Equatable {
  /// Registers that converge independently. `due_has_time` is deliberately
  /// absent: it travels inside the `due_date` register, because an all-day
  /// task and one due at 5pm differ in a single fact and splitting it would
  /// let a sync attach a time to a date that no longer wants one.
  static const Set<String> crdtFields = {
    'title',
    'description',
    'note_id',
    'due_date',
    'sort_order',
    'is_completed',
    'is_deleted',
    'priority',
    'labels',
    'recurrence',
    'reminder_at',
    'reminder_lead_minutes',
    'notebook_id',
    'parent_id',
  };

  final String id;
  final String userId;
  final String? noteId;

  /// The list this task is filed under — a notebook, so notes and tasks share
  /// one organizing tree instead of the app growing a second one.
  final String? notebookId;

  /// Parent task, for subtasks. Null for a top-level task.
  final String? parentId;

  final String title;
  final String description;
  final bool isCompleted;
  final DateTime? completedAt;
  final DateTime? dueDate;

  /// Whether [dueDate] carries a meaningful time of day.
  final bool dueHasTime;

  final TaskPriority priority;
  final List<String> labels;

  /// Serialized repetition rule (`FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH`). The
  /// Rust core owns the grammar; Dart stores and forwards it.
  final String? recurrence;

  final DateTime? reminderAt;

  /// Minutes before [dueDate] the reminder was asked for, kept beside the
  /// absolute time so rescheduling the task moves its reminder too.
  final int? reminderLeadMinutes;

  final int sortOrder;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, TaskCrdtClock> fieldClocks;

  const Task({
    required this.id,
    required this.userId,
    this.noteId,
    this.notebookId,
    this.parentId,
    required this.title,
    this.description = '',
    this.isCompleted = false,
    this.completedAt,
    this.dueDate,
    this.dueHasTime = false,
    this.priority = TaskPriority.none,
    this.labels = const [],
    this.recurrence,
    this.reminderAt,
    this.reminderLeadMinutes,
    this.sortOrder = 0,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.fieldClocks = const {},
  });

  /// True when this task repeats. Cheap enough to ask on every row build.
  bool get repeats => (recurrence ?? '').isNotEmpty;

  bool get hasReminder => reminderAt != null;

  factory Task.fromJson(Map<String, dynamic> json) {
    final due = DateTime.tryParse(json['due_date'] as String? ?? '');
    return Task(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      noteId: json['note_id'] as String?,
      notebookId: json['notebook_id'] as String?,
      parentId: json['parent_id'] as String?,
      title: json['title'] as String? ?? 'Untitled task',
      description: json['description'] as String? ?? '',
      isCompleted: json['is_completed'] as bool? ?? false,
      completedAt: DateTime.tryParse(json['completed_at'] as String? ?? ''),
      dueDate: due,
      dueHasTime: (json['due_has_time'] as bool? ?? false) && due != null,
      priority: TaskPriority.fromValue(json['priority'] as int?),
      labels: parseLabels(json['labels']),
      recurrence: _emptyToNull(json['recurrence'] as String?),
      reminderAt: DateTime.tryParse(json['reminder_at'] as String? ?? ''),
      reminderLeadMinutes: json['reminder_lead_minutes'] as int?,
      sortOrder: json['sort_order'] as int? ?? 0,
      isDeleted: json['is_deleted'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      // Same LWW contract as notes: prefer edited_at (when a human last
      // edited) over updated_at (when the server applied it).
      updatedAt:
          DateTime.tryParse(json['edited_at'] as String? ?? '') ??
          DateTime.parse(json['updated_at'] as String),
      fieldClocks: _parseFieldClocks(json['field_clocks']),
    );
  }

  static String? _emptyToNull(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  /// Read a label list from JSON or from the denormalized SQLite column.
  /// Anything malformed reads as "no labels" rather than throwing — a task
  /// with a corrupt label list must still open.
  static List<String> parseLabels(Object? raw) {
    Object? decoded = raw;
    if (raw is String) {
      if (raw.isEmpty) return const [];
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        return const [];
      }
    }
    if (decoded is! List) return const [];
    final seen = <String>{};
    final labels = <String>[];
    for (final entry in decoded) {
      if (entry is! String) continue;
      final name = entry.trim();
      if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
      labels.add(name);
    }
    return List.unmodifiable(labels);
  }

  static Map<String, TaskCrdtClock> _parseFieldClocks(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, TaskCrdtClock>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      try {
        result[entry.key as String] = TaskCrdtClock.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
      } on FormatException {
        // A malformed remote clock is ignored and falls back to updated_at.
      }
    }
    return Map.unmodifiable(result);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'note_id': noteId,
    'notebook_id': notebookId,
    'parent_id': parentId,
    'title': title,
    'description': description,
    'is_completed': isCompleted,
    'completed_at': completedAt?.toIso8601String(),
    'due_date': dueDate?.toIso8601String(),
    'due_has_time': dueHasTime,
    'priority': priority.value,
    'labels': labels,
    'recurrence': recurrence,
    'reminder_at': reminderAt?.toIso8601String(),
    'reminder_lead_minutes': reminderLeadMinutes,
    'sort_order': sortOrder,
    'is_deleted': isDeleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'field_clocks': fieldClocks.map(
      (field, clock) => MapEntry(field, clock.toJson()),
    ),
  };

  Map<String, dynamic> toSyncPatch(Set<String> fields) {
    final patch = <String, dynamic>{
      'field_clocks': {
        for (final field in fields)
          if (fieldClocks[field] != null) field: fieldClocks[field]!.toJson(),
      },
    };
    for (final field in fields) {
      switch (field) {
        case 'title':
          patch[field] = title;
        case 'description':
          patch[field] = description;
        case 'note_id':
          patch[field] = noteId;
        case 'notebook_id':
          patch[field] = notebookId;
        case 'parent_id':
          patch[field] = parentId;
        case 'due_date':
          patch[field] = dueDate?.toUtc().toIso8601String();
          // Companion of due_date, never its own register.
          patch['due_has_time'] = dueHasTime;
        case 'priority':
          patch[field] = priority.value;
        case 'labels':
          patch[field] = labels;
        case 'recurrence':
          patch[field] = recurrence;
        case 'reminder_at':
          patch[field] = reminderAt?.toUtc().toIso8601String();
        case 'reminder_lead_minutes':
          patch[field] = reminderLeadMinutes;
        case 'sort_order':
          patch[field] = sortOrder;
        case 'is_completed':
          patch[field] = isCompleted;
          patch['completed_at'] = completedAt?.toUtc().toIso8601String();
        case 'is_deleted':
          patch[field] = isDeleted;
      }
    }
    return patch;
  }

  TaskCrdtClock clockFor(String field) =>
      fieldClocks[field] ?? TaskCrdtClock(timestamp: updatedAt, deviceId: '');

  /// Join two LWW maps. Different-field edits are retained; the timestamp and
  /// device id form a deterministic total order for same-field edits.
  Task mergeCrdt(Task remote) {
    final remoteWinners = remoteWinningFields(
      fields: crdtFields,
      localClocks: _coreTaskClocks(fieldClocks),
      localFallback: _taskFallbackClock(updatedAt),
      remoteClocks: _coreTaskClocks(remote.fieldClocks),
      remoteFallback: _taskFallbackClock(remote.updatedAt),
    );
    bool takeRemote(String field) => remoteWinners.contains(field);
    final clocks = <String, TaskCrdtClock>{...fieldClocks};
    for (final field in crdtFields) {
      if (takeRemote(field)) clocks[field] = remote.clockFor(field);
    }
    final completionFromRemote = takeRemote('is_completed');
    final dueFromRemote = takeRemote('due_date');
    return Task(
      id: id,
      userId: remote.userId,
      noteId: takeRemote('note_id') ? remote.noteId : noteId,
      notebookId: takeRemote('notebook_id') ? remote.notebookId : notebookId,
      parentId: takeRemote('parent_id') ? remote.parentId : parentId,
      title: takeRemote('title') ? remote.title : title,
      description: takeRemote('description') ? remote.description : description,
      isCompleted: completionFromRemote ? remote.isCompleted : isCompleted,
      completedAt: completionFromRemote ? remote.completedAt : completedAt,
      dueDate: dueFromRemote ? remote.dueDate : dueDate,
      // Moves with due_date so the pair can never contradict each other.
      dueHasTime: dueFromRemote ? remote.dueHasTime : dueHasTime,
      priority: takeRemote('priority') ? remote.priority : priority,
      labels: takeRemote('labels') ? remote.labels : labels,
      recurrence: takeRemote('recurrence') ? remote.recurrence : recurrence,
      reminderAt: takeRemote('reminder_at') ? remote.reminderAt : reminderAt,
      reminderLeadMinutes: takeRemote('reminder_lead_minutes')
          ? remote.reminderLeadMinutes
          : reminderLeadMinutes,
      sortOrder: takeRemote('sort_order') ? remote.sortOrder : sortOrder,
      isDeleted: takeRemote('is_deleted') ? remote.isDeleted : isDeleted,
      createdAt: createdAt.isBefore(remote.createdAt)
          ? createdAt
          : remote.createdAt,
      updatedAt: updatedAt.isAfter(remote.updatedAt)
          ? updatedAt
          : remote.updatedAt,
      fieldClocks: Map.unmodifiable(clocks),
    );
  }

  /// Sentinel distinguishing "not passed" from an explicit null in [copyWith],
  /// so a due date / note link / completion stamp can be cleared.
  static const Object _unset = Object();

  Task copyWith({
    String? title,
    String? description,
    bool? isCompleted,
    Object? completedAt = _unset,
    Object? dueDate = _unset,
    bool? dueHasTime,
    Object? noteId = _unset,
    Object? notebookId = _unset,
    Object? parentId = _unset,
    TaskPriority? priority,
    List<String>? labels,
    Object? recurrence = _unset,
    Object? reminderAt = _unset,
    Object? reminderLeadMinutes = _unset,
    int? sortOrder,
    bool? isDeleted,
    DateTime? updatedAt,
    Map<String, TaskCrdtClock>? fieldClocks,
  }) {
    return Task(
      id: id,
      userId: userId,
      noteId: identical(noteId, _unset) ? this.noteId : noteId as String?,
      notebookId: identical(notebookId, _unset)
          ? this.notebookId
          : notebookId as String?,
      parentId: identical(parentId, _unset) ? this.parentId : parentId as String?,
      title: title ?? this.title,
      description: description ?? this.description,
      isCompleted: isCompleted ?? this.isCompleted,
      completedAt: identical(completedAt, _unset)
          ? this.completedAt
          : completedAt as DateTime?,
      dueDate: identical(dueDate, _unset) ? this.dueDate : dueDate as DateTime?,
      dueHasTime: dueHasTime ?? this.dueHasTime,
      priority: priority ?? this.priority,
      labels: labels ?? this.labels,
      recurrence: identical(recurrence, _unset)
          ? this.recurrence
          : recurrence as String?,
      reminderAt: identical(reminderAt, _unset)
          ? this.reminderAt
          : reminderAt as DateTime?,
      reminderLeadMinutes: identical(reminderLeadMinutes, _unset)
          ? this.reminderLeadMinutes
          : reminderLeadMinutes as int?,
      sortOrder: sortOrder ?? this.sortOrder,
      isDeleted: isDeleted ?? this.isDeleted,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      fieldClocks: fieldClocks ?? this.fieldClocks,
    );
  }

  @override
  List<Object?> get props => [
    id,
    userId,
    noteId,
    notebookId,
    parentId,
    title,
    description,
    isCompleted,
    completedAt,
    dueDate,
    dueHasTime,
    priority,
    labels,
    recurrence,
    reminderAt,
    reminderLeadMinutes,
    sortOrder,
    isDeleted,
    createdAt,
    updatedAt,
    fieldClocks,
  ];
}

Map<String, CrdtClockValue> _coreTaskClocks(
  Map<String, TaskCrdtClock> clocks,
) => {
  for (final entry in clocks.entries)
    entry.key: (
      timestampMicrosUtc: entry.value.timestamp.toUtc().microsecondsSinceEpoch,
      deviceId: entry.value.deviceId,
    ),
};

CrdtClockValue _taskFallbackClock(DateTime timestamp) => (
  timestampMicrosUtc: timestamp.toUtc().microsecondsSinceEpoch,
  deviceId: '',
);
