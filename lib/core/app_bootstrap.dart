import 'package:flutter/widgets.dart';
import '../data/repositories/auth_repository.dart';
import '../domain/services/sync_scheduler.dart';
import 'db/app_database.dart';
import 'db/meta_dao.dart';

/// Wires up the app's logic layer before the UI runs: opens the local database,
/// guarantees a stable device id, and starts background sync when a session
/// already exists. After a fresh login/register the UI should call
/// [AppBootstrap.scheduler].start() (and optionally syncNow()).
class AppBootstrap {
  AppBootstrap._();

  /// Shared scheduler so the (future) login flow can start it post-authentication.
  static final SyncScheduler scheduler = SyncScheduler();

  static Future<void> init() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Open/create the database and ensure a device id exists.
    await AppDatabase.instance.database;
    await MetaDao(AppDatabase.instance).getOrCreateDeviceId();

    // Only sync if we already have a session; otherwise wait for login.
    if (await AuthRepository().isAuthenticated) {
      scheduler.start();
    }
  }
}
