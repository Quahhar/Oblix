import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';

/// Talks to the backend `/files` API: multipart upload, binary download, list,
/// and delete. The server mints the file id and returns a `FileResponse`.
/// Dio failures surface as typed [ApiException]s (404 → [NotFoundException]…),
/// matching the other remote datasources.
class FilesRemoteDataSource {
  final Dio _dio = ApiClient().dio;

  /// Upload [bytes] as a multipart file, optionally linked to [noteId] — which
  /// must already exist on the server, or the upload 404s. Returns the server's
  /// FileResponse map (includes the minted `id`).
  Future<Map<String, dynamic>> upload({
    required List<int> bytes,
    required String filename,
    String? mimeType,
    String? noteId,
  }) {
    return _wrap(() async {
      final form = FormData.fromMap({
        'file': MultipartFile.fromBytes(
          bytes,
          filename: filename,
          contentType: _mediaType(mimeType),
        ),
      });
      final resp = await _dio.post(
        '/files/upload',
        data: form,
        queryParameters: {'note_id': ?noteId},
      );
      return resp.data as Map<String, dynamic>;
    });
  }

  Future<List<int>> download(String fileId) {
    return _wrap(() async {
      final resp = await _dio.get<List<int>>(
        '/files/$fileId/download',
        options: Options(responseType: ResponseType.bytes),
      );
      return resp.data ?? const [];
    });
  }

  Future<List<Map<String, dynamic>>> list({String? noteId}) {
    return _wrap(() async {
      final resp = await _dio.get(
        '/files',
        queryParameters: {'note_id': ?noteId},
      );
      return (resp.data as List).cast<Map<String, dynamic>>();
    });
  }

  Future<void> delete(String fileId) {
    return _wrap(() => _dio.delete('/files/$fileId'));
  }

  static Future<T> _wrap<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  static DioMediaType? _mediaType(String? mime) {
    if (mime == null || !mime.contains('/')) return null;
    try {
      return DioMediaType.parse(mime);
    } catch (_) {
      return null;
    }
  }
}
