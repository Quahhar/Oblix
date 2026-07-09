import 'dart:convert';
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

  Future<void> logout() async {
    // Best-effort server-side revocation, then always clear local state.
    final refreshToken = await SecureStorage.getRefreshToken();
    if (refreshToken != null) {
      try {
        await _remote.logout(refreshToken);
      } catch (_) {
        // Ignore — the token may already be invalid or we're offline.
      }
    }
    await SecureStorage.clearTokens();
    await _meta.clearUserScopedData();
  }

  Future<void> _onAuthenticated(Map<String, dynamic> tokens) async {
    final accessToken = tokens['access_token'] as String;
    await SecureStorage.saveTokens(
      accessToken: accessToken,
      refreshToken: tokens['refresh_token'] as String,
    );
    // Cache the user id so notes can be created offline with a real owner id.
    final userId = _subFromJwt(accessToken);
    if (userId != null) await _meta.setUserId(userId);
  }

  /// Extract the `sub` (user id) claim from a JWT without verifying it — the
  /// server is the authority; this is only for local convenience.
  static String? _subFromJwt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;
      var payload = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      payload = payload.padRight((payload.length + 3) & ~3, '=');
      final map = jsonDecode(utf8.decode(base64.decode(payload)))
          as Map<String, dynamic>;
      return map['sub'] as String?;
    } catch (_) {
      return null;
    }
  }
}
