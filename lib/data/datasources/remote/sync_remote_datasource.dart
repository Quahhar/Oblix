import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../../models/sync_payload.dart';

class SyncRemoteDataSource {
  final Dio _dio = ApiClient().dio;

  /// Push local changes; the response also carries everything that changed on
  /// the server since [lastSyncAt], so one round-trip both pushes and pulls.
  /// Throws a typed [ApiException] on failure.
  Future<SyncPushResponse> pushChanges({
    required List<SyncChangeItem> changes,
    String? lastSyncAt,
  }) async {
    try {
      final response = await _dio.post(
        '/sync/push',
        data: {
          'changes': changes.map((c) => c.toJson()).toList(),
          'last_sync_at': lastSyncAt,
        },
      );
      return SyncPushResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }
}
