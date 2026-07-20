import 'package:flutter/foundation.dart';
import '../../data/repositories/auth_repository.dart';
import '../db/app_database.dart';
import '../db/meta_dao.dart';

/// Cached display name/email for offline UI (home avatar, settings card).
/// Loads instantly from the meta table, then refreshes from /auth/me in the
/// background when possible. Cleared with the rest of the user-scoped data on
/// logout (see MetaDao.clearUserScopedData).
class ProfileCache {
  ProfileCache._();
  static final ProfileCache instance = ProfileCache._();

  final ValueNotifier<String?> name = ValueNotifier(null);
  final ValueNotifier<String?> email = ValueNotifier(null);

  bool _refreshing = false;

  Future<void> load() async {
    final meta = MetaDao(AppDatabase.instance);
    name.value = await meta.getSetting(MetaDao.kProfileName);
    email.value = await meta.getSetting(MetaDao.kProfileEmail);
    refresh();
  }

  /// Best-effort background refresh; offline failures keep the cache.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final user = await AuthRepository().getCurrentUser();
      name.value = user.displayName;
      email.value = user.email;
      final meta = MetaDao(AppDatabase.instance);
      await meta.setSetting(MetaDao.kProfileName, user.displayName);
      await meta.setSetting(MetaDao.kProfileEmail, user.email);
    } catch (_) {
      // Offline or session refresh in flight — the cached values stand.
    } finally {
      _refreshing = false;
    }
  }

  void clear() {
    name.value = null;
    email.value = null;
  }
}
