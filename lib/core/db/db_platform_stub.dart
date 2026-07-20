/// No-op on platforms where sqflite works out of the box (mobile, web).
/// The real implementation lives in `db_platform_io.dart` and is selected via
/// conditional import in `db_platform_init.dart`.
void initDatabasePlatform() {}
