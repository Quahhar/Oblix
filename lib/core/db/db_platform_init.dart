/// Picks the right database backend per platform. `dart:io` doesn't exist on
/// the web, so the IO implementation is only imported where it's available.
library;
export 'db_platform_stub.dart' if (dart.library.io) 'db_platform_io.dart';
