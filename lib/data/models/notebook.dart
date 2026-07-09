import 'package:equatable/equatable.dart';

class Notebook extends Equatable {
  final String id;
  final String userId;
  final String name;
  final String? parentId;
  final int sortOrder;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Notebook> children;

  const Notebook({
    required this.id,
    required this.userId,
    required this.name,
    this.parentId,
    this.sortOrder = 0,
    this.isDeleted = false,
    required this.createdAt,
    required this.updatedAt,
    this.children = const [],
  });

  factory Notebook.fromJson(Map<String, dynamic> json) {
    return Notebook(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String? ?? '',
      parentId: json['parent_id'] as String?,
      sortOrder: json['sort_order'] as int? ?? 0,
      isDeleted: json['is_deleted'] as bool? ?? false,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      children:
          (json['children'] as List<dynamic>?)
              ?.map((c) => Notebook.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'parent_id': parentId,
    'sort_order': sortOrder,
  };

  Notebook copyWith({
    String? name,
    String? parentId,
    int? sortOrder,
    bool? isDeleted,
    DateTime? updatedAt,
    List<Notebook>? children,
  }) {
    return Notebook(
      id: id,
      userId: userId,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      sortOrder: sortOrder ?? this.sortOrder,
      isDeleted: isDeleted ?? this.isDeleted,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      children: children ?? this.children,
    );
  }

  @override
  List<Object?> get props => [
    id,
    name,
    parentId,
    sortOrder,
    isDeleted,
    updatedAt,
  ];
}
