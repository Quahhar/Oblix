import 'package:equatable/equatable.dart';

class Task extends Equatable {
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
      updatedAt: DateTime.tryParse(json['edited_at'] as String? ?? '') ??
          DateTime.parse(json['updated_at'] as String),
    );
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
  };

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
  ];
}
