import 'package:equatable/equatable.dart';

class Tag extends Equatable {
  final String id;
  final String userId;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Tag({
    required this.id,
    required this.userId,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Tag.fromJson(Map<String, dynamic> json) {
    final created = DateTime.parse(json['created_at'] as String);
    return Tag(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String? ?? '',
      createdAt: created,
      // Older payloads may omit updated_at; fall back to created_at.
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : created,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'user_id': userId,
    'name': name,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  Tag copyWith({String? name, DateTime? updatedAt}) {
    return Tag(
      id: id,
      userId: userId,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  List<Object?> get props => [id, name, createdAt, updatedAt];
}
