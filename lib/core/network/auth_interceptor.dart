import 'package:dio/dio.dart';
import '../auth/auth_state.dart';
import '../config/api_config.dart';
import '../storage/secure_storage.dart';

class AuthInterceptor extends Interceptor {
  final Dio dio;

  /// Bare client used only for the refresh call, so refreshing never recurses
  /// back through this interceptor.
  final Dio _refreshDio;

  /// Shared in-flight refresh. Concurrent 401s await the same future instead of
  /// each firing their own refresh (which would rotate the token repeatedly and
  /// invalidate all but one, logging the user out).
  Future<String?>? _refreshing;

  AuthInterceptor(this.dio)
    : _refreshDio = Dio(BaseOptions(baseUrl: ApiConfig.apiUrl));

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final token = await SecureStorage.getAccessToken();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final path = err.requestOptions.path;
    final isAuthEndpoint =
        path.contains('/auth/refresh') || path.contains('/auth/login');

    // Only handle a single retry per request, and never try to refresh the
    // refresh/login calls themselves.
    if (err.response?.statusCode != 401 ||
        isAuthEndpoint ||
        err.requestOptions.extra['__retried__'] == true) {
      return handler.next(err);
    }

    final newToken = await _refreshAccessToken();
    if (newToken == null) {
      // Refresh failed — tokens already cleared; propagate the original error.
      return handler.next(err);
    }

    try {
      err.requestOptions.extra['__retried__'] = true;
      err.requestOptions.headers['Authorization'] = 'Bearer $newToken';
      final retryResponse = await dio.fetch(err.requestOptions);
      return handler.resolve(retryResponse);
    } catch (_) {
      return handler.next(err);
    }
  }

  /// Returns a fresh access token, or null if refresh failed. Coalesces
  /// concurrent callers onto a single network call.
  Future<String?> _refreshAccessToken() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _doRefresh() async {
    final refreshToken = await SecureStorage.getRefreshToken();
    if (refreshToken == null) return null;

    try {
      final response = await _refreshDio.post(
        '/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      if (response.statusCode == 200) {
        final newAccessToken = response.data['access_token'] as String;
        final newRefreshToken = response.data['refresh_token'] as String;
        await SecureStorage.saveTokens(
          accessToken: newAccessToken,
          refreshToken: newRefreshToken,
        );
        return newAccessToken;
      }
    } catch (_) {
      // fall through to clear tokens
    }

    // Refresh failed — clear tokens and tell the app the session is gone so
    // the UI routes to login and the sync scheduler stops. Local data is kept:
    // an expired session must not destroy unsynced notes.
    await SecureStorage.clearTokens();
    AuthState.instance.markSignedOut();
    return null;
  }
}
