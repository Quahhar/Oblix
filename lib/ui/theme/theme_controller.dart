import 'package:flutter/material.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';

enum OblixThemeCollection { classic, paper }

extension OblixThemeCollectionDetails on OblixThemeCollection {
  String get storageKey => switch (this) {
    OblixThemeCollection.classic => 'classic',
    OblixThemeCollection.paper => 'paper',
  };

  String get label => switch (this) {
    OblixThemeCollection.classic => 'Classic',
    OblixThemeCollection.paper => 'Paper',
  };

  String get description => switch (this) {
    OblixThemeCollection.classic =>
      'Clean white surfaces with a Notes-inspired accent',
    OblixThemeCollection.paper => 'Warm paper surfaces with terracotta details',
  };
}

/// App-wide appearance preferences, persisted in the meta table so they
/// survive restarts and sign-out. Classic and non-glass are deliberately the
/// defaults, including for installs created before theme collections existed.
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();

  static const _appearanceKey = 'appearance';
  static const _collectionKey = 'theme_collection';
  static const _liquidGlassKey = 'liquid_glass';

  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);
  final ValueNotifier<OblixThemeCollection> collection = ValueNotifier(
    OblixThemeCollection.classic,
  );
  final ValueNotifier<bool> liquidGlass = ValueNotifier(false);

  Future<void> load() async {
    final meta = MetaDao(AppDatabase.instance);
    final values = await Future.wait([
      meta.getSetting(_appearanceKey),
      meta.getSetting(_collectionKey),
      meta.getSetting(_liquidGlassKey),
    ]);
    mode.value = switch (values[0]) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    collection.value = switch (values[1]) {
      'paper' => OblixThemeCollection.paper,
      _ => OblixThemeCollection.classic,
    };
    liquidGlass.value = values[2] == 'true';
  }

  Future<void> set(ThemeMode value) async {
    mode.value = value;
    await MetaDao(AppDatabase.instance).setSetting(
      _appearanceKey,
      switch (value) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      },
    );
  }

  Future<void> setCollection(OblixThemeCollection value) async {
    collection.value = value;
    await MetaDao(
      AppDatabase.instance,
    ).setSetting(_collectionKey, value.storageKey);
  }

  Future<void> setLiquidGlass(bool value) async {
    liquidGlass.value = value;
    await MetaDao(
      AppDatabase.instance,
    ).setSetting(_liquidGlassKey, value.toString());
  }

  static String label(ThemeMode value) => switch (value) {
    ThemeMode.system => 'System',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };
}
