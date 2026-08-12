import 'package:dio/dio.dart';
import '../auth/auth_state.dart';
import '../config/api_config.dart';
import '../native/oblix_core.dart';
import '../storage/secure_storage.dart';

class AuthInterceptor extends Interceptor {
  final Dio dio;

  /// Bare client used only for the refresh call, so refreshing never recurses
  /// back through this interceptor. It carries the same timeouts as the main
  /// client: with Dio's defaults a stalled refresh never completes, and every
  /// request queued behind the shared future hangs with it.
  final Dio _refreshDio;

  /// Shared in-flight refresh. Concurrent 401s await the same future instead of
  /// each firing their own refresh (which would rotate the token repeatedly and
  /// invalidate all but one, logging the user out).
  Future<String?>? _refreshing;

  AuthInterceptor(this.dio, {Dio? refreshClient})
    : _refreshDio =
          refreshClient ??
          Dio(
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

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    var token = await SecureStorage.getAccessToken();
    // Refresh a known-expired token before sending rather than waiting for the
    // 401. It's the same single round trip, but it also covers the requests the
    // error path can't replay — anything already marked `__retried__`, and
    // streamed uploads whose body can't be re-sent.
    if (token != null && _isExpired(token) && !_isAuthEndpoint(options.path)) {
      token = await _refreshAccessToken() ?? token;
    }
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    // Only handle a single retry per request, and never try to refresh the
    // refresh/login calls themselves.
    if (err.response?.statusCode != 401 ||
        _isAuthEndpoint(err.requestOptions.path) ||
        err.requestOptions.extra['__retried__'] == true) {
      return handler.next(err);
    }

    final newToken = await _refreshAccessToken();
    if (newToken == null) {
      // Refresh didn't produce a token; propagate the original error.
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

  static bool _isAuthEndpoint(String path) =>
      path.contains('/auth/refresh') || path.contains('/auth/login');

  /// True when the access token is expired (or about to be). Reuses the shared
  /// JWT `exp` check — it is not specific to collaboration tokens, it just
  /// reports whether a JWT is within a minute of expiry. An unparseable token
  /// counts as expired, which costs at most one refresh attempt.
  static bool _isExpired(String token) => collaborationTokenNeedsRefresh(
    token,
    nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );

  /// Returns a fresh access token, or null if refresh failed. Coalesces
  /// concurrent callers onto a single network call.
  Future<String?> _refreshAccessToken() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<String?> _doRefresh() async {
    final refreshToken = await SecureStorage.getRefreshToken();
    if (refreshToken == null) {
      // Nothing to refresh with and no network involved, so this is definitive:
      // the session can't come back. Route to login now instead of 401ing on
      // every request until the next launch.
      await _endSession();
      return null;
    }

    try {
      final response = await _refreshDio.post(
        '/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      final data = response.data;
      if (data is Map &&
          data['access_token'] is String &&
          data['refresh_token'] is String) {
        final newAccessToken = data['access_token'] as String;
        await SecureStorage.saveTokens(
          accessToken: newAccessToken,
          refreshToken: data['refresh_token'] as String,
        );
        return newAccessToken;
      }
      // 2xx with a body we can't use: nothing to store, but nothing that says
      // the session is over either. Keep the tokens and retry later.
      return null;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // ONLY the server explicitly rejecting the refresh token means the
      // session is really gone. A timeout, a dropped connection or a 5xx says
      // nothing about the token — and those are exactly what happens when the
      // app resumes after being away: the access token expired while
      // backgrounded, the first request 401s, and the refresh goes out over a
      // radio that hasn't reconnected yet. Clearing tokens there threw away a
      // refresh token that was still good for months and dropped the user on
      // the login screen. Keep it; the next request retries.
      if (status == 401 || status == 403) {
        await _endSession();
      }
      return null;
    } catch (_) {
      // Non-Dio failure (e.g. secure storage). Same reasoning: not proof the
      // session ended, so don't end it.
      return null;
    }
  }

  /// The server rejected our refresh token — clear it and tell the app the
  /// session is gone so the UI routes to login and the sync scheduler stops.
  /// Local data is kept: an expired session must not destroy unsynced notes.
  Future<void> _endSession() async {
    await SecureStorage.clearTokens();
    AuthState.instance.markSignedOut();
  }
}
