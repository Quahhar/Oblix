import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../../models/user.dart';

class AuthRemoteDataSource {
  final Dio _dio = ApiClient().dio;

  /// Run a request, converting Dio failures to typed [ApiException]s so the
  /// UI can show a sensible message (401 → "wrong credentials", etc.).
  Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      throw ApiException.fromDio(e);
    }
  }

  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String displayName,
    String? deviceId,
  }) {
    return _guard(() async {
      final response = await _dio.post(
        '/auth/register',
        data: {
          'email': email,
          'password': password,
          'display_name': displayName,
          'device_id': deviceId,
        },
      );
      return response.data as Map<String, dynamic>;
    });
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    String? deviceId,
  }) {
    return _guard(() async {
      final response = await _dio.post(
        '/auth/login',
        data: {'email': email, 'password': password, 'device_id': deviceId},
      );
      return response.data as Map<String, dynamic>;
    });
  }

  Future<Map<String, dynamic>> googleAuth(String idToken, {String? deviceId}) {
    return _guard(() async {
      final response = await _dio.post(
        '/auth/google',
        data: {'id_token': idToken, 'device_id': deviceId},
      );
      return response.data as Map<String, dynamic>;
    });
  }

  /// Revoke this device's session server-side. Best-effort; the caller ignores
  /// failures so local logout always proceeds.
  Future<void> logout(String refreshToken) {
    return _guard(
      () => _dio.post('/auth/logout', data: {'refresh_token': refreshToken}),
    );
  }

  Future<User> getCurrentUser() {
    return _guard(() async {
      final response = await _dio.get('/auth/me');
      return User.fromJson(response.data as Map<String, dynamic>);
    });
  }
}
