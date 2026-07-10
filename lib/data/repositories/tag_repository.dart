import 'package:uuid/uuid.dart';
import '../../core/db/app_database.dart';
import '../../core/db/meta_dao.dart';
import '../../core/time/sync_clock.dart';
import '../datasources/local/outbox_dao.dart';
import '../datasources/local/tag_local_datasource.dart';
import '../models/sync_payload.dart';
import '../models/tag.dart';

/// Offline-first tags. Deletes are tombstoned (matching the server) so they
/// propagate to other devices; synced tombstones are purged after the
/// retention window.
class TagRepository {
  final AppDatabase _appDb;
  final TagLocalDataSource _local;
  final OutboxDao _outbox;
  final MetaDao _meta;
  final SyncClock _clock;
  final Uuid _uuid;

  TagRepository({
    AppDatabase? appDb,
    TagLocalDataSource? local,
    OutboxDao? outbox,
    MetaDao? meta,
    SyncClock? clock,
    Uuid? uuid,
  })  : _appDb = appDb ?? AppDatabase.instance,
        _local = local ?? TagLocalDataSource(appDb ?? AppDatabase.instance),
        _outbox = outbox ?? OutboxDao(appDb ?? AppDatabase.instance),
        _meta = meta ?? MetaDao(appDb ?? AppDatabase.instance),
        _clock = clock ??
            SyncClock(meta ?? MetaDao(appDb ?? AppDatabase.instance)),
        _uuid = uuid ?? const Uuid();

  Stream<void> get onChanged => _appDb.onChanged;

  // --- Reads (local) ---

  Future<List<Tag>> listTags() => _local.list();

  Future<Tag?> getTag(String id) => _local.getById(id);

  // --- Writes (local + outbox, one transaction) ---

  Future<Tag> createTag(String name) async {
    final now = await _clock.nowUtc();
    final tag = Tag(
      id: _uuid.v4(),
      userId: await _meta.getUserId() ?? '',
      name: name,
      createdAt: now,
      updatedAt: now,
    );
    await _persist(tag, 'create');
    return tag;
  }

  Future<Tag> renameTag(String id, String name) async {
    final existing = await _local.getById(id);
    if (existing == null) {
      throw StateError('Tag $id not found locally');
    }
    final updated = existing.copyWith(
      name: name,
      updatedAt: await _clock.nextAfter(existing.updatedAt),
    );
    await _persist(updated, 'update');
    return updated;
  }

  Future<void> deleteTag(String id) async {
    final existing = await _local.getById(id);
    if (existing == null) return;
    final deleted = existing.copyWith(
      isDeleted: true,
      updatedAt: await _clock.nextAfter(existing.updatedAt),
    );
    await _persist(deleted, 'delete');
  }

  Future<void> _persist(Tag tag, String action) async {
    final deviceId = await _meta.getOrCreateDeviceId();
    final change = SyncChangeItem(
      entityType: 'tag',
      entityId: tag.id,
      action: action,
      data: tag.toJson(),
      deviceId: deviceId,
      timestamp: tag.updatedAt.toIso8601String(),
    );
    final db = await _appDb.database;
    await db.transaction((txn) async {
      await _local.upsert(txn, tag);
      await _outbox.enqueue(txn, change);
    });
    _appDb.notifyChanged();
  }
}
