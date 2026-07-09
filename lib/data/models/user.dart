import 'package:equatable/equatable.dart';

class User extends Equatable {
  final String id;
  final String email;
  final String displayName;
  final bool isActive;
  final DateTime? createdAt;

  const User({
    required this.id,
    required this.email,
    required this.displayName,
    this.isActive = true,
    this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      email: json['email'] as String,
      displayName: json['display_name'] as String,
      isActive: json['is_active'] as bool? ?? true,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'email': email,
    'display_name': displayName,
    'is_active': isActive,
    'created_at': createdAt?.toIso8601String(),
  };

  User copyWith({
    String? id,
    String? email,
    String? displayName,
    bool? isActive,
    DateTime? createdAt,
  }) {
    return User(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  List<Object?> get props => [id, email, displayName, isActive, createdAt];
}
