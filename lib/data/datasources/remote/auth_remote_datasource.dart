import 'package:dio/dio.dart';
import '../../../core/network/api_client.dart';
import '../../models/user.dart';

class AuthRemoteDataSource {
  final Dio _dio = ApiClient().dio;

  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String displayName,
    String? deviceId,
  }) async {
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
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    String? deviceId,
  }) async {
    final response = await _dio.post(
      '/auth/login',
      data: {'email': email, 'password': password, 'device_id': deviceId},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> googleAuth(String idToken, {String? deviceId}) async {
    final response = await _dio.post(
      '/auth/google',
      data: {'id_token': idToken, 'device_id': deviceId},
    );
    return response.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> refreshToken(String refreshToken) async {
    final response = await _dio.post(
      '/auth/refresh',
      data: {'refresh_token': refreshToken},
    );
    return response.data as Map<String, dynamic>;
  }

  /// Revoke this device's session server-side. Best-effort; the caller ignores
  /// failures so local logout always proceeds.
  Future<void> logout(String refreshToken) async {
    await _dio.post('/auth/logout', data: {'refresh_token': refreshToken});
  }

  Future<User> getCurrentUser() async {
    final response = await _dio.get('/auth/me');
    return User.fromJson(response.data as Map<String, dynamic>);
  }
}
