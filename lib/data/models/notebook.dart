import 'package:equatable/equatable.dart';
import 'crdt_clock.dart';

class Notebook extends Equatable {
  static const Set<String> crdtFields = {
    'name',
    'parent_id',
    'sort_order',
    'is_deleted',
  };
  final String id;
  final String userId;
  final String name;
  final String? parentId;
  final int sortOrder;
  final bool isDeleted;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Notebook> children;
  final Map<String, CrdtClock> fieldClocks;

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
    this.fieldClocks = const {},
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
      fieldClocks: parseCrdtClocks(json['field_clocks']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'parent_id': parentId,
    'sort_order': sortOrder,
    'is_deleted': isDeleted,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'field_clocks': fieldClocks.map(
      (field, clock) => MapEntry(field, clock.toJson()),
    ),
  };

  CrdtClock clockFor(String field) =>
      fieldClocks[field] ?? CrdtClock(timestamp: updatedAt, deviceId: '');

  Notebook mergeCrdt(Notebook remote) {
    bool take(String field) =>
        remote.clockFor(field).compareTo(clockFor(field)) > 0;
    final clocks = <String, CrdtClock>{...fieldClocks};
    for (final field in crdtFields) {
      if (take(field)) clocks[field] = remote.clockFor(field);
    }
    return Notebook(
      id: id,
      userId: remote.userId,
      name: take('name') ? remote.name : name,
      parentId: take('parent_id') ? remote.parentId : parentId,
      sortOrder: take('sort_order') ? remote.sortOrder : sortOrder,
      isDeleted: take('is_deleted') ? remote.isDeleted : isDeleted,
      createdAt: createdAt.isBefore(remote.createdAt)
          ? createdAt
          : remote.createdAt,
      updatedAt: updatedAt.isAfter(remote.updatedAt)
          ? updatedAt
          : remote.updatedAt,
      children: remote.children,
      fieldClocks: Map.unmodifiable(clocks),
    );
  }

  /// Sentinel distinguishing "not passed" from an explicit null in [copyWith],
  /// so a notebook can be moved to the top level (parentId: null).
  static const Object _unset = Object();

  Notebook copyWith({
    String? name,
    Object? parentId = _unset,
    int? sortOrder,
    bool? isDeleted,
    DateTime? updatedAt,
    List<Notebook>? children,
    Map<String, CrdtClock>? fieldClocks,
  }) {
    return Notebook(
      id: id,
      userId: userId,
      name: name ?? this.name,
      parentId: identical(parentId, _unset)
          ? this.parentId
          : parentId as String?,
      sortOrder: sortOrder ?? this.sortOrder,
      isDeleted: isDeleted ?? this.isDeleted,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      children: children ?? this.children,
      fieldClocks: fieldClocks ?? this.fieldClocks,
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
    fieldClocks,
  ];
}
