import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Desktop (Windows/Linux) has no native sqflite backend, so point the global
/// `databaseFactory` at the FFI one before any `openDatabase` call. Mobile
/// platforms keep their built-in implementation.
void initDatabasePlatform() {
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
