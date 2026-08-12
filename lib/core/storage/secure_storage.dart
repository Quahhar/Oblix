import 'dart:convert';

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

  // Default iOS/macOS accessibility is "unlocked" (kSecAttrAccessibleWhenUnlocked):
  // the tokens become unreadable the moment the screen locks. Anything that
  // runs while locked — a sync the OS resumes us for, a notification action —
  // then reads null and can't tell "no session" from "can't look right now".
  // "after first unlock" keeps them readable from the first unlock after boot
  // onward, which is the normal setting for an app that syncs in the
  // background. `_this_device` keeps them out of iCloud/iTunes backups: a
  // restore onto a new phone asks for a fresh sign-in, which is the intended
  // trade for not shipping bearer tokens into a backup.
  static const _ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  static const _macOs = MacOsOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  static const _storage = FlutterSecureStorage(
    aOptions: _android,
    iOptions: _ios,
    mOptions: _macOs,
  );

  /// Both tokens live in ONE entry so the pair is written atomically. They used
  /// to be two writes, which could be interrupted (process killed on
  /// backgrounding, or the second write failing) and leave the device holding a
  /// refresh token the server had already rotated away. Replaying that token
  /// after the server's 60s reuse grace window looks exactly like token theft,
  /// so the backend revokes every session for the account — an unrecoverable
  /// logout on all devices. One key, one write, no half-updated pair.
  static const _tokensKey = 'auth_tokens';

  // Pre-atomic keys. Still read (so an existing install stays signed in across
  // the upgrade) and still deleted, but never written again.
  static const _legacyAccessTokenKey = 'access_token';
  static const _legacyRefreshTokenKey = 'refresh_token';

  // --- Tokens ---

  static Future<String?> getAccessToken() async =>
      (await _readTokens())?.accessToken;

  static Future<String?> getRefreshToken() async =>
      (await _readTokens())?.refreshToken;

  static Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await _storage.write(
      key: _tokensKey,
      value: jsonEncode({'access': accessToken, 'refresh': refreshToken}),
    );
    await _deleteIfPresent(_legacyAccessTokenKey);
    await _deleteIfPresent(_legacyRefreshTokenKey);
  }

  static Future<void> clearTokens() async {
    await _deleteIfPresent(_tokensKey);
    await _deleteIfPresent(_legacyAccessTokenKey);
    await _deleteIfPresent(_legacyRefreshTokenKey);
  }

  static Future<_TokenPair?> _readTokens() async {
    final raw = await _storage.read(key: _tokensKey);
    if (raw != null) {
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final access = map['access'];
        final refresh = map['refresh'];
        if (access is String && refresh is String) {
          return _TokenPair(access, refresh);
        }
      } on FormatException {
        // Corrupt entry: fall through to the legacy keys, then to null, which
        // routes to login rather than throwing on every request.
      }
    }
    final access = await _storage.read(key: _legacyAccessTokenKey);
    final refresh = await _storage.read(key: _legacyRefreshTokenKey);
    // An access token with no refresh token is a session that dies in <30
    // minutes with no way back; treat it as no session at all.
    if (access != null && refresh != null) return _TokenPair(access, refresh);
    return null;
  }

  /// Guard with containsKey: EncryptedSharedPreferences on some Android
  /// versions hangs indefinitely when deleting a key that doesn't exist.
  static Future<void> _deleteIfPresent(String key) async {
    if (await _storage.containsKey(key: key)) {
      await _storage.delete(key: key);
    }
  }
}

class _TokenPair {
  final String accessToken;
  final String refreshToken;
  const _TokenPair(this.accessToken, this.refreshToken);
}
