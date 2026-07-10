import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../../../core/db/app_database.dart';
import '../../models/sync_payload.dart';

/// A queued local mutation plus its stable sequence number (the ack cursor)
/// and how many pushes the server has not acknowledged it for.
class OutboxEntry {
  final int seq;
  final int attempts;
  final SyncChangeItem change;
  const OutboxEntry(this.seq, this.change, {this.attempts = 0});
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
        attempts: r['attempts'] as int? ?? 0,
      );
    }).toList();
  }

  /// Settle a pushed batch. [ackedSeqs] were acknowledged by the server
  /// (applied or conflict-resolved) and are removed. [retrySeqs] were never
  /// mentioned in the response: their attempt count is bumped and, once it
  /// reaches [maxAttempts], they are dropped as poison entries rather than
  /// blocking the queue forever. Returns how many entries were dropped.
  /// Runs inside the sync transaction.
  Future<int> settleBatch(
    DatabaseExecutor db, {
    required List<int> ackedSeqs,
    required List<int> retrySeqs,
    required int maxAttempts,
  }) async {
    if (ackedSeqs.isNotEmpty) {
      await db.delete(
        'outbox',
        where: 'seq IN (${List.filled(ackedSeqs.length, '?').join(',')})',
        whereArgs: ackedSeqs,
      );
    }
    var dropped = 0;
    if (retrySeqs.isNotEmpty) {
      final marks = List.filled(retrySeqs.length, '?').join(',');
      await db.rawUpdate(
        'UPDATE outbox SET attempts = attempts + 1 WHERE seq IN ($marks)',
        retrySeqs,
      );
      dropped = await db.delete(
        'outbox',
        where: 'seq IN ($marks) AND attempts >= ?',
        whereArgs: [...retrySeqs, maxAttempts],
      );
    }
    return dropped;
  }

  Future<int> pendingCount() async {
    final db = await _appDb.database;
    final result =
        await db.rawQuery('SELECT COUNT(*) AS c FROM outbox');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
