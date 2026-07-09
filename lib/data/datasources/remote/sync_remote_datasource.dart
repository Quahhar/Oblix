import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';
import '../../models/sync_payload.dart';

class SyncRemoteDataSource {
  final Dio _dio = ApiClient().dio;

  Future<SyncPushResponse> pushChanges({
    required List<SyncChangeItem> changes,
    String? lastSyncAt,
  }) async {
    final response = await _dio.post(
      '/sync/push',
      data: {
        'changes': changes.map((c) => c.toJson()).toList(),
        'last_sync_at': lastSyncAt,
      },
    );
    return SyncPushResponse.fromJson(response.data as Map<String, dynamic>);
  }

  Future<SyncPullResponse> pullChanges({
    String? since,
    List<String>? entityTypes,
  }) async {
    final queryParams = <String, dynamic>{};
    if (since != null) queryParams['since'] = since;
    if (entityTypes != null && entityTypes.isNotEmpty) {
      queryParams['entity_types'] = entityTypes.join(',');
    }

    final response = await _dio.get('/sync/pull', queryParameters: queryParams);
    return SyncPullResponse.fromJson(response.data as Map<String, dynamic>);
  }
}
