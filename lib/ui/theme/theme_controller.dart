import 'package:flutter/material.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';

/// App-wide appearance setting (System / Light / Dark), persisted in the meta
/// table so it survives restarts. Device-scoped: it intentionally survives
/// logout.
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _key = 'appearance';

  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);

  Future<void> load() async {
    final raw = await MetaDao(AppDatabase.instance).getSetting(_key);
    mode.value = switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> set(ThemeMode value) async {
    mode.value = value;
    await MetaDao(AppDatabase.instance).setSetting(_key, switch (value) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }

  static String label(ThemeMode value) => switch (value) {
        ThemeMode.system => 'System',
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
      };
}
