import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../../models/note.dart';

class SharedItem {
  final String shareId;
  final String entityType;
  final String entityId;
  final String role;
  final String ownerEmail;
  final String? ownerDisplayName;
  final String name;

  const SharedItem({
    required this.shareId,
    required this.entityType,
    required this.entityId,
    required this.role,
    required this.ownerEmail,
    required this.ownerDisplayName,
    required this.name,
  });

  factory SharedItem.fromJson(Map<String, dynamic> json) => SharedItem(
    shareId: json['share_id'] as String,
    entityType: json['entity_type'] as String,
    entityId: json['entity_id'] as String,
    role: json['role'] as String,
    ownerEmail: json['owner_email'] as String,
    ownerDisplayName: json['owner_display_name'] as String?,
    name: json['name'] as String? ?? 'Untitled',
  );
}

class Collaborator {
  final String id;
  final String entityType;
  final String entityId;
  final String role;
  final String email;
  final String displayName;

  const Collaborator({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.role,
    required this.email,
    required this.displayName,
  });

  factory Collaborator.fromJson(Map<String, dynamic> json) => Collaborator(
    id: json['id'].toString(),
    entityType: json['entity_type'] as String,
    entityId: json['entity_id'].toString(),
    role: json['role'] as String,
    email: json['grantee_email'] as String,
    displayName: json['grantee_display_name'] as String? ?? '',
  );
}

class CollaborationRemoteDataSource {
  final Dio _dio = ApiClient().dio;

  Future<List<SharedItem>> sharedWithMe() async {
    try {
      final response = await _dio.get('/shares/with-me');
      return [
        for (final raw in response.data as List)
          SharedItem.fromJson(Map<String, dynamic>.from(raw as Map)),
      ];
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }

  Future<List<Note>> sharedNotebookNotes(String notebookId) async {
    try {
      final notes = <Note>[];
      var page = 1;
      while (true) {
        final response = await _dio.get(
          '/shares/notebook/$notebookId/notes',
          queryParameters: {'page': page, 'page_size': 200},
        );
        final data = Map<String, dynamic>.from(response.data as Map);
        final batch = [
          for (final raw in data['notes'] as List? ?? const [])
            Note.fromJson(Map<String, dynamic>.from(raw as Map)),
        ];
        notes.addAll(batch);
        final total = data['total'] as int? ?? notes.length;
        if (notes.length >= total || batch.isEmpty) return notes;
        page++;
      }
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }

  Future<Note> getNote(String noteId) async {
    try {
      final response = await _dio.get('/notes/$noteId');
      return Note.fromJson(Map<String, dynamic>.from(response.data as Map));
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }

  Future<void> share({
    required String entityType,
    required String entityId,
    required String email,
    required String role,
  }) async {
    try {
      await _dio.post(
        '/shares',
        data: {
          'entity_type': entityType,
          'entity_id': entityId,
          'email': email,
          'role': role,
        },
      );
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }

  Future<List<Collaborator>> collaborators({
    required String entityType,
    required String entityId,
  }) async {
    try {
      final response = await _dio.get(
        '/shares',
        queryParameters: {'entity_type': entityType, 'entity_id': entityId},
      );
      return [
        for (final raw in response.data as List)
          Collaborator.fromJson(Map<String, dynamic>.from(raw as Map)),
      ];
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }

  Future<void> updateRole(String shareId, String role) async {
    try {
      await _dio.put('/shares/$shareId', data: {'role': role});
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }

  Future<void> removeShare(String shareId) async {
    try {
      await _dio.delete('/shares/$shareId');
    } on DioException catch (error) {
      throw ApiException.fromDio(error);
    }
  }
}
