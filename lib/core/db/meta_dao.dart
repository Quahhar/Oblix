import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'app_database.dart';

/// Key/value access over the `meta` table: the sync cursor, this device's id,
/// and the cached user id. Read/write methods accept a [DatabaseExecutor] so
/// they can participate in the sync transaction (commit the cursor atomically
/// with the note upserts it corresponds to).
class MetaDao {
  static const _kCursor = 'last_sync_at';
  static const _kDeviceId = 'device_id';
  static const _kUserId = 'user_id';
  static const _kClockSkewMs = 'server_clock_skew_ms';

  final AppDatabase _appDb;
  MetaDao(this._appDb);

  Future<String?> _get(DatabaseExecutor db, String key) async {
    final rows = await db.query(
      'meta',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  Future<void> _set(DatabaseExecutor db, String key, String? value) async {
    await db.insert(
      'meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // --- Sync cursor ---

  Future<String?> getCursor() async => _get(await _appDb.database, _kCursor);

  /// Advance the cursor. Pass the sync transaction as [db] so it commits with
  /// the changes it accounts for.
  Future<void> setCursor(DatabaseExecutor db, String serverTime) =>
      _set(db, _kCursor, serverTime);

  // --- Device id (stable per install) ---

  Future<String> getOrCreateDeviceId() async {
    final db = await _appDb.database;
    final existing = await _get(db, _kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = const Uuid().v4();
    await _set(db, _kDeviceId, id);
    return id;
  }

  // --- Server clock skew (serverTime - deviceTime, observed at last sync) ---
  //
  // Local write timestamps are shifted by this so a device with a wrong clock
  // doesn't lose (or unfairly win) last-write-wins merges.

  Future<Duration> getClockSkew() async {
    final raw = await _get(await _appDb.database, _kClockSkewMs);
    final ms = int.tryParse(raw ?? '');
    return Duration(milliseconds: ms ?? 0);
  }

  /// Record the skew. Pass the sync transaction as [db] so it commits with the
  /// cycle that observed it.
  Future<void> setClockSkew(DatabaseExecutor db, Duration skew) =>
      _set(db, _kClockSkewMs, skew.inMilliseconds.toString());

  // --- Cached user id (derived from the JWT `sub`) ---

  Future<String?> getUserId() async => _get(await _appDb.database, _kUserId);

  Future<void> setUserId(String userId) async =>
      _set(await _appDb.database, _kUserId, userId);

  Future<void> clearUserScopedData() async {
    // On logout: forget the sync cursor and user id, and drop all local entities
    // + the outbox so the next user doesn't see this user's data. The device id
    // is intentionally preserved (it's install-scoped, not user-scoped).
    final db = await _appDb.database;
    await db.transaction((txn) async {
      await txn.delete('notes');
      await txn.delete('notebooks');
      await txn.delete('tags');
      await txn.delete('outbox');
      await txn.delete('meta', where: 'key IN (?, ?)',
          whereArgs: [_kCursor, _kUserId]);
    });
  }
}
