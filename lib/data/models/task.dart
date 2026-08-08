import 'package:equatable/equatable.dart';

class TaskCrdtClock extends Equatable implements Comparable<TaskCrdtClock> {
  final DateTime timestamp;
  final String deviceId;

  const TaskCrdtClock({required this.timestamp, required this.deviceId});

  factory TaskCrdtClock.fromJson(Map<String, dynamic> json) => TaskCrdtClock(
    timestamp: DateTime.parse(json['timestamp'] as String).toUtc(),
    deviceId: json['device_id'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'device_id': deviceId,
  };

  @override
  int compareTo(TaskCrdtClock other) {
    final byTime = timestamp.compareTo(other.timestamp);
    return byTime != 0 ? byTime : deviceId.compareTo(other.deviceId);
  }

  @override
  List<Object?> get props => [timestamp, deviceId];
}

class Task extends Equatable {
  static const Set<String> crdtFields = {
    'title',
    'description',
    'note_id',
    'due_date',
    'sort_order',
    'is_completed',
    'is_deleted',
  };

  final String id;
  final String userId;
  final String? noteId;
  final String title;
  final String description;
  final bool isCompleted;
  final DateTime? completedAt;
  final DateTime? dueDate;
  final int sortOrder;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, TaskCrdtClock> fieldClocks;

  const Task({
    required this.id,
    required this.userId,
    this.noteId,
    required this.title,
    this.description = '',
    this.isCompleted = false,
    this.completedAt,
    this.dueDate,
    this.sortOrder = 0,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.fieldClocks = const {},
  });

  factory Task.fromJson(Map<String, dynamic> json) {
    return Task(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      noteId: json['note_id'] as String?,
      title: json['title'] as String? ?? 'Untitled task',
      description: json['description'] as String? ?? '',
      isCompleted: json['is_completed'] as bool? ?? false,
      completedAt: DateTime.tryParse(json['completed_at'] as String? ?? ''),
      dueDate: DateTime.tryParse(json['due_date'] as String? ?? ''),
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
    'title': title,
    'description': description,
    'is_completed': isCompleted,
    'completed_at': completedAt?.toIso8601String(),
    'due_date': dueDate?.toIso8601String(),
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
          break;
        case 'description':
          patch[field] = description;
          break;
        case 'note_id':
          patch[field] = noteId;
          break;
        case 'due_date':
          patch[field] = dueDate?.toUtc().toIso8601String();
          break;
        case 'sort_order':
          patch[field] = sortOrder;
          break;
        case 'is_completed':
          patch[field] = isCompleted;
          patch['completed_at'] = completedAt?.toUtc().toIso8601String();
          break;
        case 'is_deleted':
          patch[field] = isDeleted;
          break;
      }
    }
    return patch;
  }

  TaskCrdtClock clockFor(String field) =>
      fieldClocks[field] ?? TaskCrdtClock(timestamp: updatedAt, deviceId: '');

  /// Join two LWW maps. Different-field edits are retained; the timestamp and
  /// device id form a deterministic total order for same-field edits.
  Task mergeCrdt(Task remote) {
    bool takeRemote(String field) =>
        remote.clockFor(field).compareTo(clockFor(field)) > 0;
    final clocks = <String, TaskCrdtClock>{...fieldClocks};
    for (final field in crdtFields) {
      if (takeRemote(field)) clocks[field] = remote.clockFor(field);
    }
    final completionFromRemote = takeRemote('is_completed');
    return Task(
      id: id,
      userId: remote.userId,
      noteId: takeRemote('note_id') ? remote.noteId : noteId,
      title: takeRemote('title') ? remote.title : title,
      description: takeRemote('description') ? remote.description : description,
      isCompleted: completionFromRemote ? remote.isCompleted : isCompleted,
      completedAt: completionFromRemote ? remote.completedAt : completedAt,
      dueDate: takeRemote('due_date') ? remote.dueDate : dueDate,
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
    Object? noteId = _unset,
    int? sortOrder,
    bool? isDeleted,
    DateTime? updatedAt,
    Map<String, TaskCrdtClock>? fieldClocks,
  }) {
    return Task(
      id: id,
      userId: userId,
      noteId: identical(noteId, _unset) ? this.noteId : noteId as String?,
      title: title ?? this.title,
      description: description ?? this.description,
      isCompleted: isCompleted ?? this.isCompleted,
      completedAt: identical(completedAt, _unset)
          ? this.completedAt
          : completedAt as DateTime?,
      dueDate: identical(dueDate, _unset) ? this.dueDate : dueDate as DateTime?,
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
    title,
    description,
    isCompleted,
    completedAt,
    dueDate,
    sortOrder,
    isDeleted,
    createdAt,
    updatedAt,
    fieldClocks,
  ];
}
