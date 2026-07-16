import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';

/// Talks to the backend `/files` API: multipart upload, binary download, list,
/// and delete. The server mints the file id and returns a `FileResponse`.
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
  }) async {
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
  }

  Future<List<int>> download(String fileId) async {
    final resp = await _dio.get<List<int>>(
      '/files/$fileId/download',
      options: Options(responseType: ResponseType.bytes),
    );
    return resp.data ?? const [];
  }

  Future<List<Map<String, dynamic>>> list({String? noteId}) async {
    final resp = await _dio.get(
      '/files',
      queryParameters: {'note_id': ?noteId},
    );
    return (resp.data as List).cast<Map<String, dynamic>>();
  }

  Future<void> delete(String fileId) async {
    await _dio.delete('/files/$fileId');
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
