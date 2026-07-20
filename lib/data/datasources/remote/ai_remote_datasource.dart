import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';

class AiStatus {
  final bool enabled;
  final String? model;
  const AiStatus({required this.enabled, this.model});
}

/// The backend's AI endpoints (available only when the server is configured
/// with an ANTHROPIC_API_KEY — check [status] before showing AI UI).
class AiRemoteDataSource {
  final Dio _dio = ApiClient().dio;

  Future<AiStatus> status() async {
    try {
      final response = await _dio.get('/ai/status');
      final data = response.data as Map<String, dynamic>;
      return AiStatus(
        enabled: data['enabled'] as bool? ?? false,
        model: data['model'] as String?,
      );
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  /// Summarize a note. [style]: short | detailed | bullets.
  Future<String> summarize(String noteId, {String style = 'short'}) async {
    try {
      final response = await _dio.post(
        '/ai/summarize',
        data: {'note_id': noteId, 'style': style},
      );
      return (response.data as Map<String, dynamic>)['summary'] as String? ??
          '';
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}
