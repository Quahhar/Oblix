import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../config/api_config.dart';
import 'auth_interceptor.dart';

class ApiClient {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;

  late final Dio dio;

  ApiClient._internal() {
    dio = Dio(
      BaseOptions(
        baseUrl: ApiConfig.apiUrl,
        connectTimeout: ApiConfig.connectTimeout,
        receiveTimeout: ApiConfig.receiveTimeout,
        sendTimeout: ApiConfig.sendTimeout,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ),
    );

    dio.interceptors.add(AuthInterceptor(dio));

    // Body logging leaks passwords and tokens, so only enable it in debug
    // builds. Release builds still surface errors without payloads.
    if (kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(requestBody: true, responseBody: true, error: true),
      );
    }
  }
}
