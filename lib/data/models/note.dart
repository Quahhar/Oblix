import 'package:equatable/equatable.dart';

class Note extends Equatable {
  final String id;
  final String userId;
  final String? notebookId;
  final String title;
  final String content;
  final String contentType; // plain, rich, markdown
  final bool isPinned;
  final bool isArchived;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> tagNames;
  final List<NoteVersion> versions;

  const Note({
    required this.id,
    required this.userId,
    this.notebookId,
    required this.title,
    required this.content,
    this.contentType = 'plain',
    this.isPinned = false,
    this.isArchived = false,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.tagNames = const [],
    this.versions = const [],
  });

  factory Note.fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      notebookId: json['notebook_id'] as String?,
      title: json['title'] as String? ?? 'Untitled',
      content: json['content'] as String? ?? '',
      contentType: json['content_type'] as String? ?? 'plain',
      isPinned: json['is_pinned'] as bool? ?? false,
      isArchived: json['is_archived'] as bool? ?? false,
      isDeleted: json['is_deleted'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      tagNames:
          (json['tags'] as List<dynamic>?)
              ?.map(
                (t) => (t is Map<String, dynamic>)
                    ? (t['name'] as String? ?? '')
                    : t.toString(),
              )
              .toList() ??
          [],
      versions:
          (json['versions'] as List<dynamic>?)
              ?.map((v) => NoteVersion.fromJson(v as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'notebook_id': notebookId,
    'title': title,
    'content': content,
    'content_type': contentType,
    'is_pinned': isPinned,
    'is_archived': isArchived,
    'is_deleted': isDeleted,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  Note copyWith({
    String? title,
    String? content,
    String? contentType,
    String? notebookId,
    bool? isPinned,
    bool? isArchived,
    bool? isDeleted,
    DateTime? updatedAt,
    List<String>? tagNames,
    List<NoteVersion>? versions,
  }) {
    return Note(
      id: id,
      userId: userId,
      notebookId: notebookId ?? this.notebookId,
      title: title ?? this.title,
      content: content ?? this.content,
      contentType: contentType ?? this.contentType,
      isPinned: isPinned ?? this.isPinned,
      isArchived: isArchived ?? this.isArchived,
      isDeleted: isDeleted ?? this.isDeleted,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tagNames: tagNames ?? this.tagNames,
      versions: versions ?? this.versions,
    );
  }

  @override
  List<Object?> get props => [
    id,
    userId,
    notebookId,
    title,
    content,
    contentType,
    isPinned,
    isArchived,
    isDeleted,
    updatedAt,
  ];
}

class NoteVersion extends Equatable {
  final String id;
  final String title;
  final String content;
  final String contentType;
  final int versionNumber;
  final DateTime createdAt;

  const NoteVersion({
    required this.id,
    required this.title,
    required this.content,
    required this.contentType,
    required this.versionNumber,
    required this.createdAt,
  });

  factory NoteVersion.fromJson(Map<String, dynamic> json) {
    return NoteVersion(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      contentType: json['content_type'] as String? ?? 'plain',
      versionNumber: json['version_number'] as int? ?? 1,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  @override
  List<Object?> get props => [id, versionNumber, createdAt];
}
