import 'dart:convert';
import '../../core/auth/auth_state.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../core/storage/secure_storage.dart';
import '../datasources/remote/auth_remote_datasource.dart';
import '../models/user.dart';

class AuthRepository {
  final AuthRemoteDataSource _remote;
  final MetaDao _meta;

  AuthRepository({AuthRemoteDataSource? remote, MetaDao? meta})
    : _remote = remote ?? AuthRemoteDataSource(),
      _meta = meta ?? MetaDao(AppDatabase.instance);

  /// Whether the user is currently authenticated (has stored tokens).
  Future<bool> get isAuthenticated async {
    final token = await SecureStorage.getAccessToken();
    return token != null;
  }

  Future<void> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    final deviceId = await _meta.getOrCreateDeviceId();
    final tokens = await _remote.register(
      email: email,
      password: password,
      displayName: displayName,
      deviceId: deviceId,
    );
    await _onAuthenticated(tokens);
  }

  Future<void> login({required String email, required String password}) async {
    final deviceId = await _meta.getOrCreateDeviceId();
    final tokens = await _remote.login(
      email: email,
      password: password,
      deviceId: deviceId,
    );
    await _onAuthenticated(tokens);
  }

  Future<void> loginWithGoogle(String idToken) async {
    final deviceId = await _meta.getOrCreateDeviceId();
    final tokens = await _remote.googleAuth(idToken, deviceId: deviceId);
    await _onAuthenticated(tokens);
  }

  Future<User> getCurrentUser() => _remote.getCurrentUser();

  /// Explicit logout: best-effort server-side revocation, then always clear
  /// tokens AND user-scoped local data (notes, outbox, cursor). Callers that
  /// care about unsynced changes should flush the outbox first — see
  /// AppBootstrap.signOut.
  Future<void> logout() async {
    final refreshToken = await SecureStorage.getRefreshToken();
    if (refreshToken != null) {
      try {
        await _remote.logout(refreshToken);
      } catch (_) {
        // Ignore — the token may already be invalid or we're offline.
      }
    }
    // Always clear local state.  If the DB or secure storage throws we still
    // mark signed-out so the UI doesn't get stuck on the wrong route.
    await _clearLocalSession();
    AuthState.instance.markSignedOut();
  }

  /// Best-effort local cleanup.  Failures are swallowed so that the caller
  /// (logout or _onAuthenticated) can always flip [AuthState] afterwards.
  Future<void> _clearLocalSession() async {
    try {
      await SecureStorage.clearTokens();
    } catch (_) {}
    try {
      await _meta.clearUserScopedData();
    } catch (_) {}
  }

  Future<void> _onAuthenticated(Map<String, dynamic> tokens) async {
    final accessToken = tokens['access_token'] as String;
    // 1) Always blow away any stale tokens from a previous session first, and
    //    clear user-scoped data if the incoming user differs from the cached
    //    one (or if there's no cached id — a previous broken logout may have
    //    left partial state).  This is intentionally done *before* saving the
    //    new tokens so the interceptor never picks up a stale token while the
    //    database still contains the old user's data.
    final userId = _subFromJwt(accessToken);

    // 2) Defensive: if a prior logout crashed, stale user data may remain.
    //    Always clean up the old session's local data before writing the new
    //    user's id so they don't see leftover notes/notebooks.
    final cachedId = await _meta.getUserId();
    if (cachedId != null && cachedId != userId && userId != null) {
      await _clearLocalSession();
    } else if (cachedId == null) {
      // Never had a user id (fresh install) or a previous logout left token
      // cleanup but not data cleanup.  Wipe again just to be safe.
      await _clearLocalSession();
    }

    // 3) Save tokens and user id.
    await SecureStorage.saveTokens(
      accessToken: accessToken,
      refreshToken: tokens['refresh_token'] as String,
    );
    if (userId != null) {
      await _meta.setUserId(userId);
    }
    AuthState.instance.markSignedIn();
  }

  /// Extract the `sub` (user id) claim from a JWT without verifying it — the
  /// server is the authority; this is only for local convenience.
  static String? _subFromJwt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      payload = payload.padRight((payload.length + 3) & ~3, '=');
      final map =
          jsonDecode(utf8.decode(base64.decode(payload)))
              as Map<String, dynamic>;
      return map['sub'] as String?;
    } catch (_) {
      return null;
    }
  }
}
