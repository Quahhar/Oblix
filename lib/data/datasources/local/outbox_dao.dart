import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../models/sync_payload.dart';

/// A queued local mutation plus its stable sequence number (the ack cursor).
class OutboxEntry {
  final int seq;
  final SyncChangeItem change;
  const OutboxEntry(this.seq, this.change);
}

/// Durable queue of local changes waiting to be pushed. FIFO by `seq`.
class OutboxDao {
  final AppDatabase _appDb;
  OutboxDao(this._appDb);

  /// Enqueue a change. Accepts a [DatabaseExecutor] so the enqueue commits in
  /// the SAME transaction as the local write it mirrors — a row and its outbox
  /// entry are never out of step.
  Future<void> enqueue(DatabaseExecutor db, SyncChangeItem change) async {
    await db.insert('outbox', {
      'entity_type': change.entityType,
      'entity_id': change.entityId,
      'action': change.action,
      'data': jsonEncode(change.data),
      'timestamp': change.timestamp,
      'device_id': change.deviceId,
    });
  }

  /// Oldest [limit] pending changes, in FIFO order.
  Future<List<OutboxEntry>> fetchBatch({int limit = 100}) async {
    final db = await _appDb.database;
    final rows = await db.query('outbox', orderBy: 'seq ASC', limit: limit);
    return rows.map((r) {
      return OutboxEntry(
        r['seq'] as int,
        SyncChangeItem(
          entityType: r['entity_type'] as String,
          entityId: r['entity_id'] as String,
          action: r['action'] as String,
          data: (jsonDecode(r['data'] as String) as Map).cast<String, dynamic>(),
          deviceId: r['device_id'] as String?,
          timestamp: r['timestamp'] as String,
        ),
      );
    }).toList();
  }

  /// Delete every entry with `seq <= throughSeq` — i.e. exactly the batch that
  /// was just pushed. Entries enqueued during the push have a higher seq and
  /// survive for the next cycle. Runs inside the sync transaction.
  Future<void> deleteThrough(DatabaseExecutor db, int throughSeq) async {
    await db.delete('outbox', where: 'seq <= ?', whereArgs: [throughSeq]);
  }

  Future<int> pendingCount() async {
    final db = await _appDb.database;
    final result =
        await db.rawQuery('SELECT COUNT(*) AS c FROM outbox');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
