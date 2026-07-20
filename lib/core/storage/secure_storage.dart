import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorage {
  // `resetOnError: true` is the fix for "can't log in after clearing app data"
  // on Android: clearing app data wipes the encrypted prefs but often leaves
  // this app's key behind in the Android Keystore. The stale key no longer
  // matches any stored data, so reads/writes throw (or silently fail to
  // persist) forever — the freshly-saved token can't be read back, every
  // request 401s, and the user is bounced back to login. resetOnError makes
  // the plugin wipe and reinitialize its storage on such an error instead of
  // getting stuck. A first install is unaffected (there's no stale key).
  static const _android = AndroidOptions(
    encryptedSharedPreferences: true,
    resetOnError: true,
  );

  static const _storage = FlutterSecureStorage(aOptions: _android);
  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';

  // --- Tokens ---

  static Future<String?> getAccessToken() async {
    return _storage.read(key: _accessTokenKey);
  }

  static Future<String?> getRefreshToken() async {
    return _storage.read(key: _refreshTokenKey);
  }

  static Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(key: _accessTokenKey, value: accessToken);
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
  }

  static Future<void> clearTokens() async {
    // Guard with containsKey: EncryptedSharedPreferences on some Android
    // versions hangs indefinitely when deleting a key that doesn't exist.
    if (await _storage.containsKey(key: _accessTokenKey)) {
      await _storage.delete(key: _accessTokenKey);
    }
    if (await _storage.containsKey(key: _refreshTokenKey)) {
      await _storage.delete(key: _refreshTokenKey);
    }
  }
}
