import 'package:flutter/widgets.dart';
import '../data/repositories/auth_repository.dart';
import '../domain/services/sync_scheduler.dart';
import '../domain/services/task_reminder_service.dart';
import '../ui/theme/theme_controller.dart';
import '../ui/shell/dock_controller.dart';
import 'auth/auth_state.dart';
import 'db/app_database.dart';
import 'db/db_platform_init.dart';
import 'db/meta_dao.dart';
import 'native/oblix_core.dart';

/// Wires up the app's logic layer before the UI runs: opens the local database,
/// guarantees a stable device id, and keeps the background sync scheduler in
/// step with the session — running while signed in, stopped when signed out.
class AppBootstrap {
  AppBootstrap._();

  /// Shared scheduler; started/stopped by auth-state changes below.
  static final SyncScheduler scheduler = SyncScheduler();

  static Future<void> init() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Desktop platforms need the FFI SQLite backend before any openDatabase.
    initDatabasePlatform();

    // Load the platform-neutral Rust domain core before repositories can merge
    // remote entities. Web keeps the behaviorally identical Dart fallback.
    await initializeOblixCore();

    // Open/create the database and ensure a device id exists.
    await AppDatabase.instance.database;
    await MetaDao(AppDatabase.instance).getOrCreateDeviceId();
    await Future.wait([
      ThemeController.instance.load(),
      DockController.instance.load(),
    ]);

    // Re-arm task reminders from the database. Alarms do not survive a reboot
    // or a reinstall on their own, so this is what makes a reminder set last
    // month still fire. Failures are contained inside the service.
    await TaskReminderService.instance.init();

    AuthState.instance.status.addListener(_onAuthChanged);
    // Leaving `unknown` always changes the value, so the listener fires and
    // starts/stops the scheduler accordingly.
    AuthState.instance.status.value = await AuthRepository().isAuthenticated
        ? AuthStatus.signedIn
        : AuthStatus.signedOut;
  }

  static void _onAuthChanged() {
    switch (AuthState.instance.status.value) {
      case AuthStatus.signedIn:
        scheduler.start();
      case AuthStatus.signedOut:
        scheduler.stop();
      case AuthStatus.unknown:
        break;
    }
  }

  /// User-initiated sign-out: flush unsynced changes (best effort — we may be
  /// offline), then revoke the session and clear user-scoped local data.
  static Future<void> signOut() async {
    try {
      await scheduler.syncNow();
    } catch (_) {
      // Offline or server down: proceed; unsynced local edits are lost, which
      // is the explicit trade-off of a manual logout.
    }
    await AuthRepository().logout();
  }
}
